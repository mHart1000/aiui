require "test_helper"

class WebResearch::SearxngAdapterTest < ActiveSupport::TestCase
  class ChunkedResponse < Net::HTTPOK
    def initialize(chunks:)
      super("1.1", "200", "OK")
      @chunks = chunks
    end

    def read_body
      @chunks.each { |chunk| yield chunk }
    end
  end

  class FakeHttp
    attr_accessor :use_ssl, :open_timeout, :read_timeout

    def initialize(response: nil, error: nil)
      @response = response
      @error = error
    end

    def request(_request)
      raise @error if @error

      yield @response if block_given?
      @response
    end
  end

  test "rejects malformed provider JSON" do
    adapter = WebResearch::SearxngAdapter.new(base_url: "http://searx.example")
    http = FakeHttp.new(response: ChunkedResponse.new(chunks: [ "not json" ]))

    Net::HTTP.stub(:new, http) do
      error = assert_raises(WebResearch::SearxngAdapter::Error) { adapter.search("latest news") }
      assert_equal "SearXNG returned invalid JSON", error.message
    end
  end

  test "contains TLS failures and deadline breaches as provider errors" do
    adapter = WebResearch::SearxngAdapter.new(base_url: "https://searx.example")

    Net::HTTP.stub(:new, FakeHttp.new(error: OpenSSL::SSL::SSLError.new("certificate verify failed"))) do
      error = assert_raises(WebResearch::SearxngAdapter::Error) { adapter.search("latest news") }
      assert_match "certificate verify failed", error.message
    end

    http = FakeHttp.new(response: ChunkedResponse.new(chunks: [ "{}" ]))
    Net::HTTP.stub(:new, http) do
      error = assert_raises(WebResearch::SearxngAdapter::Error) do
        adapter.search("latest news", deadline: -Float::INFINITY)
      end
      assert_equal "SearXNG response timed out", error.message
    end
  end
end
