# frozen_string_literal: true

class TextToSpeechService
  DEFAULT_ADAPTER = "kokoro"

  # Streaming servers flush this WAV header before any audio; skip it for first-audio timing.
  WAV_HEADER_BYTES = 44

  # Synthesizes text to speech using the specified adapter
  # @param text [String] The text to synthesize
  # @param voice [String, nil] Voice identifier
  # @param speed [Float, nil] Playback speed multiplier
  # @param adapter [String, Symbol, nil] Which TTS adapter to use (default: ENV["TTS_ADAPTER"] or :kokoro)
  # @return [String] Raw audio bytes
  def self.call(text:, voice: nil, speed: nil, adapter: nil)
    adapter_instance = resolve_adapter(adapter)
    adapter_instance.synthesize(text: text, voice: voice, speed: speed)
  end

  # Streams synthesized audio, yielding chunks as they arrive
  # @param text [String] The text to synthesize
  # @param voice [String, nil] Voice identifier
  # @param speed [Float, nil] Playback speed multiplier
  # @param adapter [String, Symbol, nil] Which TTS adapter to use
  # @yield [String] Raw audio chunks
  def self.stream(text:, voice: nil, speed: nil, adapter: nil, &block)
    adapter_instance = resolve_adapter(adapter)
    label = adapter_instance.class.name.demodulize.sub(/Adapter\z/, "").downcase

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ttfa = nil
    bytes = 0
    header = +""
    byte_rate = nil
    result = adapter_instance.synthesize_stream(text: text, voice: voice, speed: speed) do |chunk|
      bytes += chunk.bytesize
      # First audio, not the WAV header: the header flushes instantly, so wait past it.
      if ttfa.nil? && bytes > WAV_HEADER_BYTES
        ttfa = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      end
      # Capture just the WAV header once; bytes 28-31 hold byte_rate (audio bytes/sec).
      if byte_rate.nil?
        need = WAV_HEADER_BYTES - header.bytesize
        header << chunk.byteslice(0, need) if need.positive?
        byte_rate = header.byteslice(28, 4).unpack1("V") if header.bytesize >= WAV_HEADER_BYTES
      end
      block.call(chunk)
    end

    total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    audio_s = byte_rate&.positive? ? (bytes - WAV_HEADER_BYTES).to_f / byte_rate : nil
    rtf = audio_s&.positive? ? total / audio_s : nil
    # One latency line per stream: text size, first-audio + total time, audio produced, RTF.
    Rails.logger.info(
      "TTS stream: adapter=#{label} chars=#{text.to_s.length} " \
      "ttfa_ms=#{ttfa ? (ttfa * 1000).round : "nil"} total_ms=#{(total * 1000).round} " \
      "audio_ms=#{audio_s ? (audio_s * 1000).round : "nil"} rtf=#{rtf ? rtf.round(2) : "nil"}"
    )
    result
  end

  # Whether the active adapter supports chunked streaming
  # @param adapter [String, Symbol, nil] Which TTS adapter to check
  # @return [Boolean]
  def self.streaming?(adapter: nil)
    resolve_adapter(adapter).streaming?
  end

  # Checks if the TTS backend is available
  # @param adapter [String, Symbol, nil] Which TTS adapter to check
  # @return [Boolean] true if the adapter is available
  def self.available?(adapter: nil)
    adapter_instance = resolve_adapter(adapter)
    adapter_instance.available?
  end

  # Returns available voices for the adapter
  # @param adapter [String, Symbol, nil] Which TTS adapter to query
  # @return [Array<String>] Array of voice identifiers
  def self.voices(adapter: nil)
    adapter_instance = resolve_adapter(adapter)
    adapter_instance.voices
  end

  # Resolves adapter name to adapter instance
  # Defaults to ENV["TTS_ADAPTER"] (falling back to Kokoro) when no name is given
  # @param adapter [String, Symbol, nil] Adapter name
  # @return [TtsAdapters::BaseAdapter] Adapter instance
  def self.resolve_adapter(adapter)
    name = adapter&.to_s || ENV["TTS_ADAPTER"] || DEFAULT_ADAPTER

    case name.downcase
    when "kokoro"
      TtsAdapters::KokoroAdapter.new
    when "qwen3"
      TtsAdapters::Qwen3Adapter.new
    when "chatterbox"
      TtsAdapters::ChatterboxAdapter.new
    else
      Rails.logger.warn "Unknown TTS adapter #{name.inspect}, falling back to Kokoro"
      TtsAdapters::KokoroAdapter.new
    end
  end
  private_class_method :resolve_adapter
end
