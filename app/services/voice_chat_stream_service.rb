# frozen_string_literal: true

# Streams one voice-chat turn: LLM reply -> sentence batches -> TTS -> a single
# continuous WAV byte stream (one 44-byte header, then PCM) yielded to the caller.
#
# A producer thread runs the LLM stream and pushes completed sentences onto a
# queue; the caller's thread consumes them in rolling batches (first batch is a
# single sentence for fast first audio, later batches take everything queued)
# so TTS synthesis of one batch overlaps LLM generation of the next. Works with
# whatever TTS adapter is active: the first batch's WAV header is relayed
# verbatim, and later batches have theirs stripped.
class VoiceChatStreamService
  WAV_HEADER_BYTES = 44

  class CancelledError < StandardError; end

  attr_reader :conversation

  def initialize(user:, text:, conversation_id: nil, voice: nil, speed: nil, model_code: nil)
    @user = user
    @text = text
    @voice = voice
    @speed = speed
    @conversation = user.conversations.find_by(id: conversation_id) ||
                    user.conversations.create!(title: Conversation::PLACEHOLDER_TITLE)
    @safe_model_code = @conversation.apply_model_code(model_code)
    @cancelled = false
    @thinking = +""
    @reply = +""
    @chat_result = nil
    @producer_error = nil
  end

  def stream(&sink)
    conversation.messages.create!(role: "user", content: @text)

    queue = Thread::Queue.new
    producer = start_producer(queue, conversation.messages_for_ai)

    client_disconnected = false
    consumer_error = nil
    audio_written = false

    begin
      finished = false
      first_batch = true
      until finished
        sentence = queue.pop
        break if sentence.nil?

        batch = [ sentence ]
        finished = drain_into(batch, queue) unless first_batch

        stream_batch(batch.join("\n"), strip_header: !first_batch) do |bytes|
          sink.call(bytes)
          audio_written = true
        end
        first_batch = false
      end
    rescue ActionController::Live::ClientDisconnected, IOError
      client_disconnected = true
      Rails.logger.warn("VoiceChatStreamService: client disconnected mid-stream, saving accumulated content")
    rescue => e
      consumer_error = e
    ensure
      @cancelled = true
      producer.join
    end

    persist_reply(client_disconnected: client_disconnected)

    raise consumer_error if consumer_error
    if @producer_error
      raise @producer_error unless audio_written
      Rails.logger.error("VoiceChatStreamService: LLM stream failed after audio started: #{@producer_error.class}: #{@producer_error.message}")
    end
  end

  private

  # Runs the LLM stream, accumulating text and queueing completed sentences.
  # Always pushes a nil sentinel so the consumer can't block forever.
  def start_producer(queue, messages)
    Thread.new do
      Rails.application.executor.wrap do
        chunker = SentenceChunker.new
        begin
          @chat_result = ChatService.call(
            messages: messages,
            model: @safe_model_code,
            use_persona: @user.use_persona,
            persona_id: @user.persona_id,
            use_scaffolding: false,
            stream: true,
            max_tokens: ENV.fetch("VOICE_CHAT_MAX_TOKENS", "800").to_i
          ) do |chunk, phase|
            raise CancelledError if @cancelled
            if phase == :thinking
              @thinking << chunk
            elsif phase == :response
              @reply << chunk
              chunker.feed(chunk).each { |sentence| queue << sentence }
            end
          end
          if (last = chunker.flush)
            queue << last
          end
        rescue CancelledError
          # Client went away; stop reading the LLM stream
        rescue => e
          @producer_error = e
        ensure
          queue << nil
        end
      end
    end
  end

  # Moves everything immediately available into the batch.
  # Returns true when the end-of-stream sentinel was reached.
  def drain_into(batch, queue)
    until queue.empty?
      sentence = queue.pop(true)
      return true if sentence.nil?
      batch << sentence
    end
    false
  rescue ThreadError
    false
  end

  # Synthesizes one batch with the active adapter and yields its audio bytes.
  # The wire format is one WAV header for the whole response stream, so every
  # batch after the first has its header stripped (it can arrive split across
  # chunks from a streaming adapter).
  def stream_batch(text, strip_header:, &sink)
    skip = strip_header ? WAV_HEADER_BYTES : 0
    emit = lambda do |chunk|
      if skip.positive?
        drop = [ skip, chunk.bytesize ].min
        skip -= drop
        chunk = chunk.byteslice(drop, chunk.bytesize - drop)
      end
      sink.call(chunk) unless chunk.empty?
    end

    if TextToSpeechService.streaming?
      TextToSpeechService.stream(text: text, voice: @voice, speed: @speed, &emit)
    else
      emit.call(TextToSpeechService.call(text: text, voice: @voice, speed: @speed, format: "wav"))
    end
  end

  def persist_reply(client_disconnected:)
    return unless @reply.present? || @thinking.present?

    conversation.add_assistant_message(
      reply: @reply,
      thinking: @thinking,
      tokens: @chat_result&.dig(:tokens),
      stats: @chat_result&.dig(:stats),
      persona_version: @chat_result&.dig(:persona_version)
    )
    conversation.entitle_async(@text) unless client_disconnected
  end
end
