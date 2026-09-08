require "test_helper"

class WebResearch::PageFetcherTest < ActiveSupport::TestCase
  class ChunkedResponse < Net::HTTPOK
    def initialize(chunks:, headers: {})
      super("1.1", "200", "OK")
      @chunks = chunks
      headers.each { |key, value| self[key] = value }
    end

    def read_body
      @chunks.each { |chunk| yield chunk }
    end
  end

  class RedirectResponse < Net::HTTPFound
    def initialize(location)
      super("1.1", "302", "Found")
      self["location"] = location
    end

    def read_body
    end
  end

  class FakeHttp
    attr_accessor :ipaddr, :use_ssl, :verify_mode, :open_timeout, :read_timeout
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

    def use_ssl?
      @use_ssl
    end
  end

  test "accepts public addresses and rejects private, reserved, and IPv4-mapped addresses" do
    fetcher = WebResearch::PageFetcher.new

    assert fetcher.send(:public_address?, IPAddr.new("8.8.8.8"))
    refute fetcher.send(:public_address?, IPAddr.new("127.0.0.1"))
    refute fetcher.send(:public_address?, IPAddr.new("169.254.169.254"))
    refute fetcher.send(:public_address?, IPAddr.new("192.0.2.1"))
    refute fetcher.send(:public_address?, IPAddr.new("::ffff:127.0.0.1"))
    refute fetcher.send(:public_address?, IPAddr.new("::ffff:169.254.169.254"))
    refute fetcher.send(:public_address?, IPAddr.new("192.88.99.2"))
    refute fetcher.send(:public_address?, IPAddr.new("64:ff9b:1::1"))
    refute fetcher.send(:public_address?, IPAddr.new("100:0:0:1::1"))
    refute fetcher.send(:public_address?, IPAddr.new("2001:2::1"))
    refute fetcher.send(:public_address?, IPAddr.new("2001:5::1"))
    refute fetcher.send(:public_address?, IPAddr.new("2001:40::1"))
    refute fetcher.send(:public_address?, IPAddr.new("2001:ff::1"))
    refute fetcher.send(:public_address?, IPAddr.new("3fff::1"))
    refute fetcher.send(:public_address?, IPAddr.new("5f00::1"))
  end

  test "rejects unsafe URL forms before connecting" do
    fetcher = WebResearch::PageFetcher.new
    unsafe_urls = [
      "ftp://public.example/file",
      "https://user:password@public.example/article",
      "https://public.example:8443/article",
      "//public.example/article",
      "/relative/article"
    ]

    unsafe_urls.each do |url|
      assert_raises(WebResearch::PageFetcher::UnsafeTarget, url) do
        fetcher.validate_target!(url)
      end
    end
  end

  test "rejects hostnames that do not resolve" do
    fetcher = WebResearch::PageFetcher.new

    Resolv.stub(:getaddresses, []) do
      error = assert_raises(WebResearch::PageFetcher::Error) do
        fetcher.validate_target!("https://missing.example/article")
      end

      assert_equal "hostname did not resolve", error.message
    end
  end

  test "does not retain snippets for a rejected target" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "metadata endpoint" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      [ { title: "Private", url: "http://169.254.169.254/latest", snippet: "do not expose", published_at: nil } ]
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |*_args|
      raise WebResearch::PageFetcher::UnsafeTarget, "private address"
    end

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    assert_equal "failed", result[:metadata][:status]
    assert_empty result[:metadata][:sources]
    assert_nil result[:evidence]
  end

  test "rejects a hostname with mixed public and private DNS answers" do
    fetcher = WebResearch::PageFetcher.new

    Resolv.stub(:getaddresses, [ "8.8.8.8", "127.0.0.1" ]) do
      error = assert_raises(WebResearch::PageFetcher::UnsafeTarget) do
        fetcher.validate_target!("https://mixed.example/article")
      end

      assert_equal "hostname resolved to a non-public address", error.message
    end
  end

  test "pins the validated address and does not use a proxy" do
    fetcher = WebResearch::PageFetcher.new
    response = ChunkedResponse.new(chunks: [ "Pinned response" ], headers: { "content-type" => "text/plain" })
    http = FakeHttp.new(response: response)
    net_http_arguments = nil

    Resolv.stub(:getaddresses, [ "8.8.8.8" ]) do
      Net::HTTP.stub(:new, ->(*arguments) { net_http_arguments = arguments; http }) do
        fetched = fetcher.fetch("https://public.example/article")
        assert_equal "Pinned response", fetched.text
        refute fetched.truncated
      end
    end

    assert_equal [ "public.example", 443, nil ], net_http_arguments
    assert_equal "8.8.8.8", http.ipaddr
    assert_equal "public.example", http.last_request["Host"]
    assert_equal "identity", http.last_request["Accept-Encoding"]
  end

  test "validates every redirect target before fetching it" do
    fetcher = WebResearch::PageFetcher.new
    validations = []
    responses = [
      [ RedirectResponse.new("https://final.example/article"), "" ],
      [ ChunkedResponse.new(chunks: [ "Final text" ], headers: { "content-type" => "text/plain" }), "Final text" ]
    ]

    fetcher.stub(:validate_target!, ->(url, **) {
      validations << url
      [ URI.parse(url), "8.8.8.8" ]
    }) do
      fetcher.stub(:request, ->(*_) { responses.shift }) do
        fetched = fetcher.fetch("https://initial.example/start")
        assert_equal "Final text", fetched.text
        refute fetched.truncated
      end
    end

    assert_equal [ "https://initial.example/start", "https://final.example/article" ], validations
  end

  test "rejects a malformed redirect location" do
    fetcher = WebResearch::PageFetcher.new
    uri = URI("https://initial.example/start")

    fetcher.stub(:validate_target!, [ uri, "8.8.8.8" ]) do
      fetcher.stub(:request, [ RedirectResponse.new("http://[not-a-host"), "" ]) do
        error = assert_raises(WebResearch::PageFetcher::Error) { fetcher.fetch(uri.to_s) }
        assert_match "invalid HTTP response", error.message
      end
    end
  end

  test "rejects redirects without a location and redirect loops" do
    fetcher = WebResearch::PageFetcher.new
    uri = URI("https://initial.example/start")

    fetcher.stub(:validate_target!, [ uri, "8.8.8.8" ]) do
      fetcher.stub(:request, [ RedirectResponse.new(""), "" ]) do
        error = assert_raises(WebResearch::PageFetcher::Error) { fetcher.fetch(uri.to_s) }
        assert_equal "redirect missing location", error.message
      end
    end

    requests = 0
    fetcher.stub(:validate_target!, [ uri, "8.8.8.8" ]) do
      fetcher.stub(:request, ->(*) {
        requests += 1
        [ RedirectResponse.new(uri.to_s), "" ]
      }) do
        error = assert_raises(WebResearch::PageFetcher::Error) { fetcher.fetch(uri.to_s) }
        assert_equal "too many redirects", error.message
      end
    end

    assert_equal WebResearch::PageFetcher::MAX_REDIRECTS + 1, requests
  end

  test "rejects malformed HTTP responses and expired research deadlines" do
    fetcher = WebResearch::PageFetcher.new
    uri = URI("https://public.example/article")

    fetcher.stub(:validate_target!, [ uri, "8.8.8.8" ]) do
      fetcher.stub(:request, ->(*_) { raise Net::HTTPBadResponse, "bad status line" }) do
        error = assert_raises(WebResearch::PageFetcher::Error) { fetcher.fetch(uri.to_s) }
        assert_match "invalid HTTP response", error.message
      end
    end

    error = assert_raises(WebResearch::PageFetcher::Error) do
      fetcher.fetch(uri.to_s, deadline: -Float::INFINITY)
    end
    assert_equal "research deadline exceeded", error.message
  end

  test "enforces the streamed response body limit" do
    fetcher = WebResearch::PageFetcher.new
    response = ChunkedResponse.new(
      chunks: [ "a" * WebResearch::PageFetcher::MAX_BODY_BYTES, "b" ],
      headers: { "content-type" => "text/plain" }
    )
    http = FakeHttp.new(response: response)

    Net::HTTP.stub(:new, http) do
      error = assert_raises(WebResearch::PageFetcher::Error) do
        fetcher.send(:request, URI("https://public.example/article"), "8.8.8.8", WebResearch::PageFetcher.monotonic_now + 1)
      end

      assert_equal "response body was too large", error.message
    end
  end

  test "rejects unsupported content types and encodings" do
    fetcher = WebResearch::PageFetcher.new
    uri = URI("https://public.example/article")

    json_response = ChunkedResponse.new(chunks: [ "{}" ], headers: { "content-type" => "application/json" })
    fetcher.stub(:validate_target!, [ uri, "8.8.8.8" ]) do
      Net::HTTP.stub(:new, FakeHttp.new(response: json_response)) do
        error = assert_raises(WebResearch::PageFetcher::Error) { fetcher.fetch(uri.to_s) }
        assert_equal "unsupported content type", error.message
      end
    end

    compressed_response = ChunkedResponse.new(
      chunks: [ "compressed" ],
      headers: { "content-type" => "text/html", "content-encoding" => "gzip" }
    )
    fetcher.stub(:validate_target!, [ uri, "8.8.8.8" ]) do
      Net::HTTP.stub(:new, FakeHttp.new(response: compressed_response)) do
        error = assert_raises(WebResearch::PageFetcher::Error) { fetcher.fetch(uri.to_s) }
        assert_equal "unsupported content encoding", error.message
      end
    end
  end

  test "contains TLS and network failures as fetch errors" do
    fetcher = WebResearch::PageFetcher.new
    uri = URI("https://public.example/article")
    failures = [
      OpenSSL::SSL::SSLError.new("certificate verify failed"),
      Net::ReadTimeout.new("read timed out"),
      Errno::ECONNREFUSED.new
    ]

    failures.each do |failure|
      fetcher.stub(:validate_target!, [ uri, "8.8.8.8" ]) do
        Net::HTTP.stub(:new, FakeHttp.new(error: failure)) do
          assert_raises(WebResearch::PageFetcher::Error, failure.class.name) { fetcher.fetch(uri.to_s) }
        end
      end
    end
  end

  test "strips active HTML and caps extracted text" do
    fetcher = WebResearch::PageFetcher.new
    html = <<~HTML
      <html><body>
        <header>Header text</header>
        <nav>Navigation text</nav>
        <main>Useful <strong>article</strong> text</main>
        <script>alert('script text')</script>
        <style>.secret { display: none }</style>
        <form>Form text</form>
        <iframe>Frame text</iframe>
        <footer>Footer text</footer>
      </body></html>
    HTML

    extracted = fetcher.send(:extract_text, html, "text/html")

    assert_equal "Useful article text", extracted.text
    refute extracted.truncated
    capped = fetcher.send(:extract_text, "x" * (WebResearch::PageFetcher::MAX_TEXT_LENGTH + 1), "text/plain")
    assert_operator capped.text.length, :<=, WebResearch::PageFetcher::MAX_TEXT_LENGTH
    assert capped.truncated
  end

  test "prefers semantic main content over the surrounding page shell" do
    fetcher = WebResearch::PageFetcher.new
    html = <<~HTML
      <html><body>
        <div>Account and promotional shell</div>
        <main><h1>Article title</h1><p>Useful article content.</p></main>
        <div>Unrelated recommendations</div>
      </body></html>
    HTML

    extracted = fetcher.send(:extract_text, html, "text/html")

    assert_equal "Article title\n\nUseful article content.", extracted.text
    refute_includes extracted.text, "promotional shell"
    refute_includes extracted.text, "recommendations"
  end

  test "selects query-relevant passages from long content and marks truncation" do
    fetcher = WebResearch::PageFetcher.new
    unrelated = 7.times.map do |index|
      "<p>Section #{index} discusses unrelated background material. #{'filler ' * 180}</p>"
    end.join
    html = "<article>#{unrelated}<p>Needleterm appears in the relevant passage with the requested facts.</p></article>"

    extracted = fetcher.send(:extract_text, html, "text/html", query: "needleterm facts")

    assert extracted.truncated
    assert_includes extracted.text, "Needleterm appears"
    refute_includes extracted.text, "Section 0"
    assert_operator extracted.text.length, :<=, WebResearch::PageFetcher::MAX_TEXT_LENGTH
  end

  test "uses a readable boundary when a selected passage must be clipped" do
    fetcher = WebResearch::PageFetcher.new
    text = "A complete sentence. " * 400

    extracted = fetcher.send(:extract_text, text, "text/plain")

    assert extracted.truncated
    assert_match(/[.!?](?:…)?\z/, extracted.text)
    assert_operator extracted.text.length, :<=, WebResearch::PageFetcher::MAX_TEXT_LENGTH
  end

  test "rejects HTML without readable content" do
    fetcher = WebResearch::PageFetcher.new

    error = assert_raises(WebResearch::PageFetcher::Error) do
      fetcher.send(:extract_text, "<script>only active content</script>", "text/html")
    end

    assert_equal "page had no readable text", error.message
  end
end
