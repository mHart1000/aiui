require "test_helper"

class VoiceChatStreamServiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  FAKE_HEADER = ("H" * VoiceChatStreamService::WAV_HEADER_BYTES).freeze

  # Yields a WAV header split across chunks, then PCM — like qwen3/chatterbox
  class FakeStreamingAdapter
    attr_reader :batch_texts

    def initialize
      @batch_texts = []
    end

    def streaming?
      true
    end

    def synthesize_stream(text:, voice: nil, speed: nil)
      @batch_texts << text
      yield FAKE_HEADER.byteslice(0, 10)
      yield FAKE_HEADER.byteslice(10, 34)
      yield "AUDIO#{@batch_texts.length}"
    end
  end

  # Returns one complete WAV body per call — like Kokoro
  class FakeSynthAdapter
    attr_reader :batch_texts, :formats

    def initialize
      @batch_texts = []
      @formats = []
    end

    def streaming?
      false
    end

    def synthesize(text:, voice: nil, speed: nil, format: "mp3")
      @batch_texts << text
      @formats << format
      "#{FAKE_HEADER}AUDIO#{@batch_texts.length}"
    end
  end

  setup do
    @user = User.create!(email: "voice@example.com", password: "password123")
  end

  teardown do
    Message.delete_all
    Conversation.delete_all
    User.delete_all
  end

  # Runs the service against the dev-echo LLM and a fake TTS adapter
  def run_stream(adapter, text: "Hi. Bye.", conversation_id: nil, &sink)
    output = +""
    sink ||= ->(bytes) { output << bytes }
    service = nil
    with_env("AI_ENABLED" => "false", "TTS_ADAPTER" => "kokoro") do
      TtsAdapters::KokoroAdapter.stub(:new, adapter) do
        service = VoiceChatStreamService.new(user: @user, text: text, conversation_id: conversation_id)
        service.stream(&sink)
      end
    end
    [ service, output ]
  end

  test "relays the first WAV header and strips it from later batches (streaming adapter)" do
    adapter = FakeStreamingAdapter.new
    _service, output = run_stream(adapter)

    # Rolling batches: the first is a single sentence for fast first audio
    assert_equal [ "[DEV MODE] Echo: Hi.", "Bye." ], adapter.batch_texts
    assert_equal FAKE_HEADER + "AUDIO1" + "AUDIO2", output
  end

  test "non-streaming adapters are asked for wav and stripped per batch" do
    adapter = FakeSynthAdapter.new
    _service, output = run_stream(adapter)

    assert_equal %w[wav wav], adapter.formats
    assert_equal FAKE_HEADER + "AUDIO1" + "AUDIO2", output
  end

  test "persists both messages and enqueues the title job on clean completion" do
    service = nil
    assert_enqueued_with(job: ConversationEntitleJob) do
      service, = run_stream(FakeStreamingAdapter.new)
    end

    conversation = service.conversation
    assert_equal Conversation::PLACEHOLDER_TITLE, conversation.title
    messages = conversation.messages.order(:created_at)
    assert_equal %w[user assistant], messages.map(&:role)
    assert_equal "Hi. Bye.", messages.first.content
    assert_equal "[DEV MODE] Echo: Hi. Bye.", messages.last.content
  end

  test "continues an existing conversation" do
    existing = @user.conversations.create!(title: "Ongoing")
    service, = run_stream(FakeStreamingAdapter.new, conversation_id: existing.id)

    assert_equal existing.id, service.conversation.id
    assert_equal %w[user assistant], existing.messages.order(:created_at).map(&:role)
  end

  test "unknown conversation_id creates a fresh conversation" do
    service, = run_stream(FakeStreamingAdapter.new, conversation_id: 999_999)

    assert service.conversation.persisted?
    assert_not_equal 999_999, service.conversation.id
  end

  test "applies a valid model_code to the conversation" do
    existing = @user.conversations.create!(title: "Ongoing")
    service = VoiceChatStreamService.new(
      user: @user, text: "hi", conversation_id: existing.id, model_code: "claude-opus-4-5"
    )

    assert_equal existing.id, service.conversation.id
    assert_equal "claude-opus-4-5", existing.reload.model_code
  end

  test "persists the partial reply without a title job when the client disconnects" do
    sink = ->(_bytes) { raise ActionController::Live::ClientDisconnected }

    service = nil
    assert_no_enqueued_jobs(only: ConversationEntitleJob) do
      service, = run_stream(FakeStreamingAdapter.new, &sink)
    end

    assistant = service.conversation.messages.where(role: "assistant").last
    assert assistant.present?, "partial assistant message should be persisted"
    assert assistant.content.start_with?("[DEV MODE] Echo:")
  end

  test "raises when the LLM fails before any audio" do
    failing = lambda { |**_kwargs, &_block| raise "LLM down" }
    adapter = FakeStreamingAdapter.new

    with_env("TTS_ADAPTER" => "kokoro") do
      TtsAdapters::KokoroAdapter.stub(:new, adapter) do
        ChatService.stub(:call, failing) do
          service = VoiceChatStreamService.new(user: @user, text: "hi")
          error = assert_raises(RuntimeError) { service.stream { |_bytes| } }
          assert_equal "LLM down", error.message
        end
      end
    end
  end
end
