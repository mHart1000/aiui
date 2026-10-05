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

  class ForbiddenResponse < Net::HTTPForbidden
    def initialize
      super("1.1", "403", "Forbidden")
    end

    def read_body
      yield "forbidden"
    end
  end

  class FakeHttp
    attr_accessor :use_ssl, :open_timeout, :read_timeout
    attr_reader :last_request

    def initialize(response: nil, error: nil)
      @response = response
      @error = error
    end

    def request(request)
      @last_request = request
      raise @error if @error

      yield @response if block_given?
      @response
    end
  end

  test "normalizes and caps successful search results" do
    adapter = WebResearch::SearxngAdapter.new(base_url: "http://searx.example")
    results = 6.times.map do |index|
      {
        "title" => index.zero? ? "T" * 600 : "Result #{index}",
        "url" => "https://result#{index}.example/article",
        "content" => index.zero? ? "S" * 3_100 : "Snippet #{index}",
        "publishedDate" => index.zero? ? "D" * 120 : nil
      }
    end
    http = FakeHttp.new(response: ChunkedResponse.new(chunks: [ { "results" => results }.to_json ]))

    Net::HTTP.stub(:new, http) do
      normalized = adapter.search("latest news", count: 10)

      assert_equal WebResearch::SearxngAdapter::MAX_RESULTS, normalized.length
      assert_equal WebResearch::SearxngAdapter::MAX_TITLE_LENGTH, normalized.first[:title].length
      assert_equal WebResearch::SearxngAdapter::MAX_SNIPPET_LENGTH, normalized.first[:snippet].length
      assert_equal WebResearch::SearxngAdapter::MAX_DATE_LENGTH, normalized.first[:published_at].length
      assert_equal "https://result0.example/article", normalized.first[:url]
    end

    assert_instance_of Net::HTTP::Post, http.last_request
    assert_equal "identity", http.last_request["Accept-Encoding"]
    assert_includes http.last_request.body, "format=json"
  end

  test "discards malformed and unsafe provider results" do
    adapter = WebResearch::SearxngAdapter.new(base_url: "http://searx.example")
    results = [
      nil,
      { "title" => "Credentials", "url" => "https://user:password@example.com/private", "content" => "secret" },
      { "title" => "Unsafe scheme", "url" => "file:///etc/passwd", "content" => "secret" },
      { "title" => "Valid", "url" => "https://valid.example/article", "content" => "usable" }
    ]
    http = FakeHttp.new(response: ChunkedResponse.new(chunks: [ { "results" => results }.to_json ]))

    Net::HTTP.stub(:new, http) do
      normalized = adapter.search("latest news")

      assert_equal [ "https://valid.example/article" ], normalized.map { |result| result[:url] }
    end
  end

  test "rejects malformed provider JSON" do
    adapter = WebResearch::SearxngAdapter.new(base_url: "http://searx.example")
    http = FakeHttp.new(response: ChunkedResponse.new(chunks: [ "not json" ]))

    Net::HTTP.stub(:new, http) do
      error = assert_raises(WebResearch::SearxngAdapter::Error) { adapter.search("latest news") }
      assert_equal "SearXNG returned invalid JSON", error.message
      assert_instance_of JSON::ParserError, error.cause
    end
  end

  test "rejects malformed result structures and non-success responses" do
    adapter = WebResearch::SearxngAdapter.new(base_url: "http://searx.example")

    Net::HTTP.stub(:new, FakeHttp.new(response: ChunkedResponse.new(chunks: [ "[]" ]))) do
      error = assert_raises(WebResearch::SearxngAdapter::Error) { adapter.search("latest news") }
      assert_equal "SearXNG returned malformed results", error.message
    end

    Net::HTTP.stub(:new, FakeHttp.new(response: ForbiddenResponse.new)) do
      error = assert_raises(WebResearch::SearxngAdapter::Error) { adapter.search("latest news") }
      assert_equal "SearXNG returned 403", error.message
    end
  end

  test "rejects missing or wrongly typed results instead of treating them as empty" do
    adapter = WebResearch::SearxngAdapter.new(base_url: "http://searx.example")
    [ {}, { results: nil }, { results: {} }, { results: "broken" } ].each do |payload|
      http = FakeHttp.new(response: ChunkedResponse.new(chunks: [ payload.to_json ]))
      Net::HTTP.stub(:new, http) do
        assert_raises(WebResearch::SearxngAdapter::Error) { adapter.search("example") }
      end
    end
  end

  test "preserves and logs engine failures even with HTTP success and usable results" do
    adapter = WebResearch::SearxngAdapter.new(base_url: "http://searx.example")
    failures = [ [ "google", "CAPTCHA" ] ]
    [ [], [ { url: "https://example.com", title: "Example" } ] ].each do |results|
      http = FakeHttp.new(response: ChunkedResponse.new(chunks: [ { results: results, unresponsive_engines: failures }.to_json ]))
      logged = []
      WebResearch::AuditLog.stub(:warn, ->(event, **data) { logged << [ event, data ] }) do
        Net::HTTP.stub(:new, http) do
          response = adapter.search("example")
          assert_equal results.length, response.length
          assert_equal failures, response.engine_failures
        end
      end
      assert_equal "search_engine_failed", logged.first.first
      assert_equal failures, logged.first.last[:engine_failures]
    end
  end

  test "enforces the streamed provider response limit" do
    adapter = WebResearch::SearxngAdapter.new(base_url: "http://searx.example")
    response = ChunkedResponse.new(chunks: [
      "a" * WebResearch::SearxngAdapter::MAX_RESPONSE_BYTES,
      "b"
    ])

    Net::HTTP.stub(:new, FakeHttp.new(response: response)) do
      error = assert_raises(WebResearch::SearxngAdapter::Error) { adapter.search("latest news") }
      assert_equal "SearXNG response was too large", error.message
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
      assert_nil http.last_request
    end
  end
end
