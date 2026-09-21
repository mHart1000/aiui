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
    request = WebResearch::ToolRequest.new({ "queries" => [ "metadata endpoint" ] }, authorized_user_content: "")
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

  test "does not start HTTP work when DNS consumes the remaining deadline" do
    fetcher = WebResearch::PageFetcher.new
    now = 0.0
    http = FakeHttp.new(response: ChunkedResponse.new(chunks: [ "late" ]))

    fetcher.stub(:monotonic_now, -> { now }) do
      Resolv.stub(:getaddresses, ->(_) { now = 1.0; [ "8.8.8.8" ] }) do
        Net::HTTP.stub(:new, http) do
          error = assert_raises(WebResearch::PageFetcher::Error) do
            fetcher.fetch("https://public.example/article", deadline: 1.0)
          end
          assert_equal "research deadline exceeded", error.message
          assert_nil http.last_request
        end
      end
    end
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
    assert_equal "thin", extracted.extraction_status
    capped = fetcher.send(:extract_text, "x" * (WebResearch::PageFetcher::MAX_TEXT_LENGTH + 1), "text/plain")
    assert_operator capped.text.length, :<=, WebResearch::PageFetcher::MAX_TEXT_LENGTH
    assert capped.truncated
    assert_equal "bounded", capped.extraction_status
  end

  test "prefers substantial semantic main content over the surrounding page shell" do
    fetcher = WebResearch::PageFetcher.new
    article_text = "Useful article content with enough detail to identify the semantic container as substantive. " * 4
    html = <<~HTML
      <html><body>
        <div>Account and promotional shell</div>
        <main><h1>Article title</h1><p>#{article_text}</p></main>
        <div>Unrelated recommendations</div>
      </body></html>
    HTML

    extracted = fetcher.send(:extract_text, html, "text/html")

    assert_includes extracted.text, "Article title"
    assert_includes extracted.text, "Useful article content"
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
    assert_includes extracted.text, WebResearch::PageFetcher::OMISSION_MARKER
    assert_operator extracted.text.length, :<=, WebResearch::PageFetcher::MAX_TEXT_LENGTH
  end

  test "falls back to cleaned body text when a semantic root is suspiciously thin" do
    fetcher = WebResearch::PageFetcher.new
    useful_body = "Useful server-rendered details outside the article container. " * 8
    html = "<body><article><h1>Short title</h1></article><p>#{useful_body}</p></body>"

    extracted = fetcher.send(:extract_text, html, "text/html")

    assert_includes extracted.text, "Short title"
    assert_includes extracted.text, "Useful server-rendered details"
    assert_equal "full", extracted.extraction_status
  end

  test "preserves useful text from unconventional containers when structured blocks are thin" do
    fetcher = WebResearch::PageFetcher.new
    useful_body = "Useful details rendered in a generic container. " * 8
    html = "<body><main><h1>Short title</h1></main><div>#{useful_body}</div></body>"

    extracted = fetcher.send(:extract_text, html, "text/html")

    assert_includes extracted.text, "Short title"
    assert_includes extracted.text, "Useful details rendered in a generic container"
    assert_equal "full", extracted.extraction_status
  end

  test "retains table captions and labeled values after substantial paragraph text" do
    introduction = "Background information about available models. " * 8
    html = <<~HTML
      <main><p>#{introduction}</p>
        <table><caption>Model specifications</caption>
          <thead><tr><th>Model</th><th>Context</th></tr></thead>
          <tbody>
            <tr><td><p>Needle<strong>Model</strong></p></td><td>131072</td></tr>
            <tr><td>OtherModel</td><td>32768</td></tr>
          </tbody>
        </table>
        <p>After the specifications.</p>
      </main>
    HTML

    extracted = WebResearch::PageFetcher.new.send(:extract_text, html, "text/html", query: "NeedleModel context")

    assert_includes extracted.text, "Model: NeedleModel | Context: 131072"
    assert_includes extracted.text, "Model: OtherModel | Context: 32768"
    assert_operator extracted.text.index("Background"), :<, extracted.text.index("Model specifications")
    assert_operator extracted.text.index("Model specifications"), :<, extracted.text.index("NeedleModel")
    assert_operator extracted.text.index("OtherModel"), :<, extracted.text.index("After the specifications")
    assert_equal 1, extracted.text.scan("131072").length
    assert_equal "full", extracted.extraction_status
  end

  test "retains spanning and headerless table cells without inventing column associations" do
    html = <<~HTML
      <main>
        <table>
          <tr><th>Model</th><th>Context</th></tr>
          <tr><td colspan="2">Applies to every model</td></tr>
          <tr><td>NeedleModel</td><td>131072</td></tr>
        </table>
        <table><tr><td>Free tier</td><td></td><td>Available</td></tr></table>
      </main>
    HTML

    extracted = WebResearch::PageFetcher.new.send(:extract_text, html, "text/html")

    assert_includes extracted.text, "Applies to every model"
    assert_includes extracted.text, "NeedleModel | 131072"
    assert_includes extracted.text, "Free tier |  | Available"
    refute_includes extracted.text, "Model:"
  end

  test "retains definition terms with descriptions and grouped definitions after substantial paragraphs" do
    html = <<~HTML
      <main><p>#{"Background details about the offering. " * 8}</p>
        <dl>
          <dt>Context window</dt><dd><p>131072 tokens</p><p>Shared by input and output.</p></dd>
          <dt>Price</dt><dt>Cost</dt><dd>Free for local use.</dd><dd>Hardware is separate.</dd>
          <div><dt>License</dt><dd>Apache 2.0</dd></div>
          <dt>Standalone term</dt>
        </dl>
      </main>
    HTML

    extracted = WebResearch::PageFetcher.new.send(:extract_text, html, "text/html")

    assert_includes extracted.text, "Context window: 131072 tokens"
    assert_includes extracted.text, "Context window: Shared by input and output."
    assert_includes extracted.text, "Price / Cost: Free for local use."
    assert_includes extracted.text, "Price / Cost: Hardware is separate."
    assert_includes extracted.text, "License: Apache 2.0"
    assert extracted.text.end_with?("Standalone term")
    assert_equal "full", extracted.extraction_status
  end

  test "retains generic and inline text in order without duplicating nested paragraphs or list items" do
    introduction = "Background text with sufficient length to count as substantive. " * 5
    html = <<~HTML
      <main><p>#{introduction}</p>
        Lead-in <span>text</span>.
        <div>First fact: <strong>131072</strong> tokens.<section>Second fact.</section>Third fact.</div>
        <blockquote><p>Quoted fact.</p></blockquote>
        <ul><li><p>Outer item.</p><ul><li>Inner item.</li></ul></li></ul>
        <div>Line one.<br>Line two.</div>Tail text.
      </main>
    HTML

    extracted = WebResearch::PageFetcher.new.send(:extract_text, html, "text/html")

    assert_equal [ introduction.strip, "Lead-in text.", "First fact: 131072 tokens.", "Second fact.",
      "Third fact.", "Quoted fact.", "Outer item.", "Inner item.", "Line one.", "Line two.", "Tail text." ], extracted.text.split("\n\n")
    assert_equal "full", extracted.extraction_status
  end

  test "selects relevant structured facts beyond long introductions within the page budget" do
    introduction = 8.times.map { |index| "<p>Background #{index}. #{'Unrelated details. ' * 70}</p>" }.join
    html = <<~HTML
      <main>#{introduction}
        <table><tr><th>Model</th><th>Context</th></tr>
          #{20.times.map { |index| "<tr><td>Other#{index}</td><td>32768</td></tr>" }.join}
          <tr><td>NeedleModel</td><td>131072 tokens</td></tr>
        </table>
        <dl><dt>NeedleModel license</dt><dd>Apache 2.0</dd></dl>
        <div>NeedleModel requires 24 GB of memory.</div>
      </main>
    HTML

    extracted = WebResearch::PageFetcher.new.send(:extract_text, html, "text/html", query: "NeedleModel context license memory")

    assert_includes extracted.text, "Model: NeedleModel | Context: 131072 tokens"
    assert_includes extracted.text, "NeedleModel license: Apache 2.0"
    assert_includes extracted.text, "NeedleModel requires 24 GB of memory."
    assert_includes extracted.text, WebResearch::PageFetcher::OMISSION_MARKER
    assert_equal "bounded", extracted.extraction_status
    assert_operator extracted.text.length, :<=, WebResearch::PageFetcher::MAX_TEXT_LENGTH
  end

  test "uses discriminative query coverage instead of repeated generic terms" do
    fetcher = WebResearch::PageFetcher.new
    generic = 7.times.map do |index|
      "<p>Generic section #{index}: #{'course ' * 170}</p>"
    end.join
    relevant = "<p>The AI and ML specialization contains the requested curriculum details.</p>"
    html = "<article>#{generic}#{relevant}</article>"

    extracted = fetcher.send(:extract_text, html, "text/html", query: "AI ML course specialization curriculum")

    assert_includes extracted.text, "AI and ML specialization"
    assert_includes extracted.text, WebResearch::PageFetcher::OMISSION_MARKER
  end

  test "does not discard promotional-looking text based on its wording" do
    fetcher = WebResearch::PageFetcher.new
    text = "Tuition, enrollment, start dates, flexibility, and transfer credits may be directly relevant to a user's question. " * 3

    extracted = fetcher.send(:extract_text, "<main><p>#{text}</p></main>", "text/html")

    assert_includes extracted.text, "Tuition, enrollment, start dates"
    assert_equal "full", extracted.extraction_status
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
