require "test_helper"

class TextToSpeechServiceTest < ActiveSupport::TestCase
  def setup
    @mock_adapter = Minitest::Mock.new
  end

  test "call delegates to adapter synthesize and returns audio bytes" do
    @mock_adapter.expect(:synthesize, "audio_bytes", [], text: "Hello", voice: nil, speed: nil)
    TtsAdapters::KokoroAdapter.stub(:new, @mock_adapter) do
      result = TextToSpeechService.call(text: "Hello")
      assert_equal "audio_bytes", result
    end
    @mock_adapter.verify
  end

  test "available? delegates to adapter" do
    @mock_adapter.expect(:available?, true)
    TtsAdapters::KokoroAdapter.stub(:new, @mock_adapter) do
      assert TextToSpeechService.available?
    end
    @mock_adapter.verify
  end

  test "voices delegates to adapter" do
    @mock_adapter.expect(:voices, %w[af_heart af_nova])
    TtsAdapters::KokoroAdapter.stub(:new, @mock_adapter) do
      assert_equal %w[af_heart af_nova], TextToSpeechService.voices
    end
    @mock_adapter.verify
  end

  test "qwen3 adapter name resolves to Qwen3Adapter" do
    @mock_adapter.expect(:available?, true)
    TtsAdapters::Qwen3Adapter.stub(:new, @mock_adapter) do
      assert TextToSpeechService.available?(adapter: "qwen3")
    end
    @mock_adapter.verify
  end

  test "chatterbox adapter name resolves to ChatterboxAdapter" do
    @mock_adapter.expect(:available?, true)
    TtsAdapters::ChatterboxAdapter.stub(:new, @mock_adapter) do
      assert TextToSpeechService.available?(adapter: "chatterbox")
    end
    @mock_adapter.verify
  end

  test "TTS_ADAPTER env var selects the default adapter" do
    previous = ENV["TTS_ADAPTER"]
    ENV["TTS_ADAPTER"] = "qwen3"
    @mock_adapter.expect(:available?, true)
    TtsAdapters::Qwen3Adapter.stub(:new, @mock_adapter) do
      assert TextToSpeechService.available?
    end
    @mock_adapter.verify
  ensure
    previous.nil? ? ENV.delete("TTS_ADAPTER") : ENV["TTS_ADAPTER"] = previous
  end

  test "stream delegates chunks to adapter synthesize_stream" do
    chunks = []
    fake_adapter = Object.new
    def fake_adapter.synthesize_stream(text:, voice: nil, speed: nil)
      yield "chunk1"
      yield "chunk2"
    end
    TtsAdapters::KokoroAdapter.stub(:new, fake_adapter) do
      TextToSpeechService.stream(text: "Hello") { |c| chunks << c }
    end
    assert_equal %w[chunk1 chunk2], chunks
  end

  test "adapter streaming capability flags" do
    assert TtsAdapters::ChatterboxAdapter.new.streaming?
    refute TtsAdapters::KokoroAdapter.new.streaming?
    refute TtsAdapters::Qwen3Adapter.new.streaming?
  end

  test "unknown adapter name falls back to KokoroAdapter" do
    @mock_adapter.expect(:available?, true)
    TtsAdapters::KokoroAdapter.stub(:new, @mock_adapter) do
      TextToSpeechService.available?(adapter: "nonexistent")
    end
    assert_nothing_raised { @mock_adapter.verify }
  end
end
