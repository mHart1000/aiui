require "test_helper"

class TtsAdapters::OmnivoiceAdapterTest < ActiveSupport::TestCase
  class Response < Net::HTTPOK
    def initialize(body)
      super("1.1", "200", "OK")
      @read = true
      @body = body
    end
  end

  class FailedResponse < Net::HTTPInternalServerError
    def initialize(body)
      super("1.1", "500", "Internal Server Error")
      @read = true
      @body = body
    end
  end

  test "synthesizes MP3 through the OpenAI speech endpoint" do
    captured_request = nil
    http = Object.new
    http.define_singleton_method(:request) do |request|
      captured_request = request
      Response.new("audio-bytes")
    end

    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &block) { block.call(http) }) do
      result = TtsAdapters::OmnivoiceAdapter.new.synthesize(
        text: "Hello", voice: "alloy", speed: 1.2
      )
      assert_equal "audio-bytes", result
    end

    assert_equal "/v1/audio/speech", captured_request.path
    assert_equal({
      "model" => "omnivoice",
      "input" => "Hello",
      "voice" => "alloy",
      "speed" => 1.2,
      "response_format" => "mp3"
    }, JSON.parse(captured_request.body))
  end

  test "returns selectable voice identifiers without the design placeholder" do
    body = {
      voices: [
        { id: "auto", type: "auto" },
        { id: "design:<attributes>", type: "design" },
        { id: "alloy", type: "preset" },
        { id: "clone:narrator", type: "clone" }
      ]
    }.to_json

    Net::HTTP.stub(:get_response, Response.new(body)) do
      assert_equal %w[auto alloy clone:narrator], TtsAdapters::OmnivoiceAdapter.new.voices
    end
  end

  test "raises when voice discovery fails" do
    response = FailedResponse.new("voice registry unavailable")

    Net::HTTP.stub(:get_response, response) do
      error = assert_raises(RuntimeError) { TtsAdapters::OmnivoiceAdapter.new.voices }
      assert_includes error.message, "voice registry unavailable"
    end
  end

  test "preserves provider failure details" do
    http = Object.new
    http.define_singleton_method(:request) { |_request| FailedResponse.new("model crashed") }

    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &block) { block.call(http) }) do
      error = assert_raises(RuntimeError) do
        TtsAdapters::OmnivoiceAdapter.new.synthesize(text: "Hello")
      end
      assert_includes error.message, "500 Internal Server Error"
      assert_includes error.message, "model crashed"
    end
  end

  test "rejects successful responses that report no speech" do
    response = Response.new("invalid audio")
    response["X-No-Speech-Detected"] = "true"
    http = Object.new
    http.define_singleton_method(:request) { |_request| response }

    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &block) { block.call(http) }) do
      error = assert_raises(RuntimeError) do
        TtsAdapters::OmnivoiceAdapter.new.synthesize(text: "Hello")
      end
      assert_equal "OmniVoice TTS reported that synthesis produced no speech", error.message
    end
  end

  test "is available only when the model is ready" do
    ready = Response.new({ ready: true, model_loaded: true }.to_json)
    loading = Response.new({ ready: false, model_loaded: false }.to_json)

    Net::HTTP.stub(:get_response, ready) do
      assert TtsAdapters::OmnivoiceAdapter.new.available?
    end
    Net::HTTP.stub(:get_response, loading) do
      refute TtsAdapters::OmnivoiceAdapter.new.available?
    end
  end

  test "serializes buffered prefetch" do
    assert_equal 1, TtsAdapters::OmnivoiceAdapter.new.buffered_prefetch_ahead
  end
end
