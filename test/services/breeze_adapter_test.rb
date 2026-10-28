require "test_helper"
require "tempfile"

class TtsAdapters::BreezeAdapterTest < ActiveSupport::TestCase
  class Response < Net::HTTPOK
    def initialize(body)
      super("1.1", "200", "OK")
      @read = true
      @body = body
    end

    def read_body
      return @body unless block_given?

      yield @body.byteslice(0, 2)
      yield @body.byteslice(2..)
    end
  end

  class FailedResponse < Net::HTTPConflict
    def initialize(body)
      super("1.1", "409", "Conflict")
      @read = true
      @body = body
    end

    def read_body
      return @body unless block_given?

      yield @body
    end
  end

  def setup
    @previous_env = ENV.to_h.slice(
      "BREEZE_TTS_URL",
      "BREEZE_TTS_VOICE",
      "BREEZE_TTS_INSTRUCTION",
      "BREEZE_TTS_CFG_SCALE",
      "BREEZE_TTS_SEED",
      "BREEZE_TTS_REFERENCE_AUDIO",
      "BREEZE_TTS_REFERENCE_TEXT"
    )
    ENV.delete("BREEZE_TTS_URL")
    ENV.delete("BREEZE_TTS_VOICE")
    ENV.delete("BREEZE_TTS_INSTRUCTION")
    ENV.delete("BREEZE_TTS_CFG_SCALE")
    ENV.delete("BREEZE_TTS_SEED")
    ENV.delete("BREEZE_TTS_REFERENCE_AUDIO")
    ENV.delete("BREEZE_TTS_REFERENCE_TEXT")
  end

  def teardown
    %w[
      BREEZE_TTS_URL
      BREEZE_TTS_VOICE
      BREEZE_TTS_INSTRUCTION
      BREEZE_TTS_CFG_SCALE
      BREEZE_TTS_SEED
      BREEZE_TTS_REFERENCE_AUDIO
      BREEZE_TTS_REFERENCE_TEXT
    ].each { |name| ENV.delete(name) }
    @previous_env.each { |name, value| ENV[name] = value }
  end

  test "synthesizes a complete WAV through the multipart speech endpoint" do
    captured_request = nil
    http = Object.new
    http.define_singleton_method(:request) do |request|
      captured_request = request
      Response.new("\x01\x02\x03\x04".b)
    end

    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &block) { block.call(http) }) do
      result = TtsAdapters::BreezeAdapter.new.synthesize(text: "Hello")
      assert_equal "RIFF", result.byteslice(0, 4)
      assert_equal "WAVE", result.byteslice(8, 4)
      assert_equal 24_000, result.byteslice(24, 4).unpack1("V")
      assert_equal 4, result.byteslice(40, 4).unpack1("V")
      assert_equal "\x01\x02\x03\x04".b, result.byteslice(44..)
    end

    assert_equal "/v1/audio/speech", captured_request.path
    assert_match %r{multipart/form-data; boundary=aiui-breeze-}, captured_request["Content-Type"]
    assert_includes captured_request.body, "name=\"text\"\r\n\r\nHello"
    assert_includes captured_request.body,
                    "name=\"instruction\"\r\n\r\nA warm, natural adult woman with clear conversational delivery."
    assert_includes captured_request.body, "name=\"cfg_scale\"\r\n\r\n4.0"
    assert_includes captured_request.body, "name=\"seed\"\r\n\r\n42"
  end

  test "streams a WAV header before progressive PCM chunks" do
    response = Response.new("abcd".b)
    http = Object.new
    http.define_singleton_method(:request) do |_request, &block|
      block.call(response)
    end
    chunks = []

    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &block) { block.call(http) }) do
      TtsAdapters::BreezeAdapter.new.synthesize_stream(text: "Hello") do |chunk|
        chunks << chunk
      end
    end

    assert_equal 44, chunks.first.bytesize
    assert_equal "RIFF", chunks.first.byteslice(0, 4)
    assert_equal 0xffffffff, chunks.first.byteslice(40, 4).unpack1("V")
    assert_equal %w[ab cd], chunks.drop(1)
  end

  test "uses reference audio and exact transcript for stable voice cloning" do
    Tempfile.create([ "breeze-reference", ".wav" ]) do |file|
      file.binmode
      file.write("RIFF-reference-audio".b)
      file.flush
      ENV["BREEZE_TTS_REFERENCE_AUDIO"] = file.path
      ENV["BREEZE_TTS_REFERENCE_TEXT"] = "This is the exact reference transcript."
      captured_request = nil
      http = Object.new
      http.define_singleton_method(:request) do |request|
        captured_request = request
        Response.new("pcm".b)
      end

      Net::HTTP.stub(:start, ->(*_args, **_kwargs, &block) { block.call(http) }) do
        TtsAdapters::BreezeAdapter.new.synthesize(text: "A new sentence.")
      end

      assert_includes captured_request.body, "name=\"ref_text\"\r\n\r\nThis is the exact reference transcript."
      assert_includes captured_request.body, "name=\"ref_audio\"; filename=\"#{File.basename(file.path)}\""
      assert_includes captured_request.body, "RIFF-reference-audio".b
      refute_includes captured_request.body, "name=\"instruction\""
      refute_includes captured_request.body, "name=\"cfg_scale\""
    end
  end

  test "requires reference audio and transcript together" do
    ENV["BREEZE_TTS_REFERENCE_AUDIO"] = "/tmp/reference.wav"

    error = assert_raises(ArgumentError) { TtsAdapters::BreezeAdapter.new }
    assert_includes error.message,
                    "BREEZE_TTS_REFERENCE_AUDIO and BREEZE_TTS_REFERENCE_TEXT must be provided together"
  end

  test "preserves streaming provider failure details before yielding audio" do
    response = FailedResponse.new('{"detail":"An inference request is already running."}')
    http = Object.new
    http.define_singleton_method(:request) do |_request, &block|
      block.call(response)
    end
    yielded = []

    Net::HTTP.stub(:start, ->(*_args, **_kwargs, &block) { block.call(http) }) do
      error = assert_raises(RuntimeError) do
        TtsAdapters::BreezeAdapter.new.synthesize_stream(text: "Hello") do |chunk|
          yielded << chunk
        end
      end
      assert_includes error.message, "409 Conflict"
      assert_includes error.message, "inference request is already running"
    end
    assert_empty yielded
  end

  test "exposes the configured voice profile and rejects unknown profiles" do
    ENV["BREEZE_TTS_VOICE"] = "calm_narrator"
    adapter = TtsAdapters::BreezeAdapter.new

    assert_equal %w[calm_narrator], adapter.voices
    error = assert_raises(ArgumentError) do
      adapter.synthesize(text: "Hello", voice: "qwen_voice")
    end
    assert_includes error.message, "Unknown Breeze voice"
  end

  test "is available when the loaded model endpoint reports a frame rate" do
    ready = Response.new({ frame_rate: 12.5, model_digest: "digest" }.to_json)
    invalid = Response.new({ frame_rate: 0 }.to_json)

    Net::HTTP.stub(:get_response, ready) do
      assert TtsAdapters::BreezeAdapter.new.available?
    end
    Net::HTTP.stub(:get_response, invalid) do
      refute TtsAdapters::BreezeAdapter.new.available?
    end
  end

  test "streams immediately and serializes buffered fallback" do
    adapter = TtsAdapters::BreezeAdapter.new

    assert adapter.streaming?
    assert_equal 1, adapter.first_batch_min_sentences
    assert_equal 1, adapter.buffered_prefetch_ahead
  end
end
