require "test_helper"

class TtsAdapters::OmnivoiceAdapterTest < ActiveSupport::TestCase
  class Response < Net::HTTPOK
    def initialize(body)
      super("1.1", "200", "OK")
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
end
