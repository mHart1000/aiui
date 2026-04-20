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

  test "unknown adapter name falls back to KokoroAdapter" do
    @mock_adapter.expect(:available?, true)
    TtsAdapters::KokoroAdapter.stub(:new, @mock_adapter) do
      TextToSpeechService.available?(adapter: "nonexistent")
    end
    assert_nothing_raised { @mock_adapter.verify }
  end
end
