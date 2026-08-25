require "test_helper"

class LlamaCapabilitiesTest < ActiveSupport::TestCase
  FakeHttp = Struct.new(:response, :failure) do
    attr_accessor :open_timeout, :read_timeout

    def get(_path)
      raise failure if failure
      response
    end
  end

  def setup
    LlamaCapabilities.reset!
  end

  def teardown
    LlamaCapabilities.reset!
  end

  def http_response(body, code: "200")
    klass = code == "200" ? Net::HTTPOK : Net::HTTPInternalServerError
    response = klass.new("1.1", code, "test")
    response.instance_variable_set(:@body, body.to_json)
    response.instance_variable_set(:@read, true)
    response
  end

  def with_http(response: nil, failure: nil)
    Net::HTTP.stub(:new, FakeHttp.new(response, failure)) { yield }
  end

  test "returns true when llama.cpp reports vision true" do
    with_http(response: http_response({ modalities: { vision: true } })) do
      assert_equal true, LlamaCapabilities.image_input
    end
  end

  test "returns false when llama.cpp reports vision false" do
    with_http(response: http_response({ modalities: { vision: false } })) do
      assert_equal false, LlamaCapabilities.image_input
    end
  end

  test "returns nil for a missing modality" do
    with_http(response: http_response({ model_path: "model.gguf" })) do
      assert_nil LlamaCapabilities.image_input
    end
  end

  test "returns nil on server and transport failures" do
    with_http(response: http_response({}, code: "500")) do
      assert_nil LlamaCapabilities.image_input
    end
    LlamaCapabilities.reset!
    with_http(failure: Errno::ECONNREFUSED.new) do
      assert_nil LlamaCapabilities.image_input
    end
  end

  test "verified results cache for sixty seconds" do
    LlamaCapabilities.stub(:fetch_image_input, true) do
      LlamaCapabilities.stub(:monotonic_now, 100.0) { LlamaCapabilities.image_input }
    end

    assert_equal 160.0, LlamaCapabilities.instance_variable_get(:@expires_at)
  end

  test "unavailable results cache for ten seconds" do
    LlamaCapabilities.stub(:fetch_image_input, nil) do
      LlamaCapabilities.stub(:monotonic_now, 100.0) { LlamaCapabilities.image_input }
    end

    assert_equal 110.0, LlamaCapabilities.instance_variable_get(:@expires_at)
  end

  test "refresh resets a cached result" do
    calls = 0
    fetcher = -> { calls += 1; calls == 1 }
    LlamaCapabilities.stub(:fetch_image_input, fetcher) do
      assert_equal true, LlamaCapabilities.image_input
      assert_equal true, LlamaCapabilities.image_input
      assert_equal false, LlamaCapabilities.image_input(refresh: true)
    end

    assert_equal 2, calls
  end
end
