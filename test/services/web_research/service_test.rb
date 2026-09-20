require "test_helper"

class WebResearch::ServiceTest < ActiveSupport::TestCase
  test "caps web-only evidence and keeps metadata aligned with included sources" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      [
        { title: "One", url: "https://example.com/one", snippet: "", published_at: nil },
        { title: "Two", url: "https://example.com/two", snippet: "", published_at: nil }
      ]
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |url, **| url.end_with?("one") ? "a" * 200 : "b" * 200 }

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher, max_evidence_chars: 500).call

    assert_operator result[:evidence].length, :<=, 500
    assert_equal [ 1 ], result[:metadata][:sources].map { |source| source[:id] }
    assert_includes result[:evidence], '"id":1'
    assert_not_includes result[:evidence], '"id":2'
  end

  test "logs queries, sources, bounded extracts, and the completed evidence summary" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example query" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      [ { title: "One", url: "https://example.com/one?tracking=secret", snippet: "", published_at: nil } ]
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |_url, **| "Useful source text" }

    log_output = capture_rails_logs do
      WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call
    end

    assert_includes log_output, 'event=search_started data={"query":"example query"'
    assert_includes log_output, "https://example.com/one"
    refute_includes log_output, "tracking=secret"
    assert_includes log_output, "event=page_extract_ready"
    assert_includes log_output, "Useful source text"
    assert_includes log_output, "event=research_completed"
    assert_includes log_output, "event=research_latency"
  end

  test "skips the second query when the first fills the candidate pool" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "primary", "fallback" ] }, latest_user_content: "")
    searched = []
    adapter = Object.new
    adapter.define_singleton_method(:search) do |query, **_options|
      searched << query
      WebResearch::Service::MAX_FETCH_ATTEMPTS.times.map do |index|
        { title: "Result #{index}", url: "https://example.com/#{index}", snippet: "", published_at: nil }
      end
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |url, **| "Text from #{url}" }

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    assert_equal [ "primary" ], searched
    assert_equal [ "primary" ], result[:metadata][:queries]
  end

  test "uses the second query when the first leaves page capacity" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "primary", "fallback" ] }, latest_user_content: "")
    searched = []
    adapter = Object.new
    adapter.define_singleton_method(:search) do |query, **_options|
      searched << query
      suffixes = query == "primary" ? [] : [ "two", "three" ]
      suffixes.map { |suffix| { title: suffix, url: "https://example.com/#{suffix}", snippet: "", published_at: nil } }
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |url, **| "Text from #{url}" }

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    assert_equal [ "primary", "fallback" ], searched
    assert_equal [ "primary", "fallback" ], result[:metadata][:queries]
  end

  test "deduplicates provider results by normalized URL" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "primary", "fallback" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |query, **_options|
      if query == "primary"
        [
          { title: "One", url: "https://example.com/one", snippet: "first", published_at: nil },
          { title: "Duplicate", url: "https://example.com/one", snippet: "duplicate", published_at: nil }
        ]
      else
        [
          { title: "Duplicate again", url: "https://example.com/one", snippet: "duplicate", published_at: nil },
          { title: "Two", url: "https://example.com/two", snippet: "second", published_at: nil }
        ]
      end
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |url, **| "Text from #{url}" }

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    urls = result[:metadata][:sources].map { |source| source[:url] }
    refute_empty urls
    assert_equal urls.uniq, urls
  end

  test "uses a bounded search snippet after an ordinary fetch failure" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      [ { title: "One", url: "https://example.com/one", snippet: "Provider snippet", published_at: nil } ]
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |*, **| raise WebResearch::PageFetcher::Error, "unsupported content encoding" }

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    assert_equal "partial", result[:metadata][:status]
    assert_includes result[:evidence], '"content":"Provider snippet"'
    assert_includes result[:evidence], '"content_type":"search_snippet"'
  end

  test "returns a warning without evidence when every source fails" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      [ { title: "One", url: "https://example.com/one", snippet: "", published_at: nil } ]
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |*, **| raise WebResearch::PageFetcher::Error, "timeout" }

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    assert_nil result[:evidence]
    assert_equal "failed", result[:metadata][:status]
    assert_equal "Web research did not return usable evidence.", result[:metadata][:warning]
    assert_empty result[:metadata][:sources]
  end

  test "degrades to partial evidence when an early search query fails" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "primary", "fallback" ] }, latest_user_content: "")
    searched = []
    adapter = Object.new
    adapter.define_singleton_method(:search) do |query, **_options|
      searched << query
      raise WebResearch::SearxngAdapter::Error, "response timed out" if query == "primary"

      [ { title: "Fallback", url: "https://example.com/fallback", snippet: "Fallback snippet", published_at: nil } ]
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |url, **_options|
      WebResearch::PageFetcher::FetchResult.new(text: "Substantive fallback content. " * 12, truncated: false)
    end

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    assert_equal [ "primary", "fallback" ], searched
    assert_not_nil result[:evidence]
    assert_equal "partial", result[:metadata][:status]
    assert_includes result[:metadata][:warning], "Web search was incomplete"
    assert_includes result[:metadata][:sources].map { |source| source[:url] }, "https://example.com/fallback"
  end

  test "reports no evidence without raising when every search query fails" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "primary", "fallback" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) { |*, **| raise WebResearch::SearxngAdapter::Error, "unavailable" }
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |*| "unused" }

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    assert_nil result[:evidence]
    assert_equal "failed", result[:metadata][:status]
    assert_empty result[:metadata][:sources]
  end

  test "fetches candidates concurrently and preserves candidate order" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    candidates = %w[one two three four five]
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      candidates.map do |suffix|
        { title: suffix, url: "https://example.com/#{suffix}", snippet: "", published_at: nil }
      end
    end
    started = Queue.new
    release = Queue.new
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |url, **_options|
      started << url
      release.pop
      "Text from #{url}"
    end

    fetch_count = [ candidates.length, WebResearch::Service::MAX_FETCH_ATTEMPTS ].min
    service_thread = Thread.new { WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call }
    Timeout.timeout(1) { fetch_count.times { started.pop } }
    fetch_count.times { release << true }
    result = service_thread.value

    order = result[:metadata][:sources].map { |source| candidates.index(source[:title]) }
    refute_empty order
    assert_equal order.sort, order
  ensure
    fetch_count&.times { release << true }
    service_thread&.join(1)
  end

  test "passes the research query to fetches and reports partial evidence" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      %w[one two three four five].map do |suffix|
        { title: suffix, url: "https://example.com/#{suffix}", snippet: "Snippet #{suffix}", published_at: nil }
      end
    end
    fetched = Queue.new
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |url, query:, **_options|
      suffix = URI(url).path.delete_prefix("/")
      fetched << [ suffix, query ]
      raise WebResearch::PageFetcher::Error, "blocked" if %w[one two].include?(suffix)

      text = "Substantive text from #{suffix}. " * 12
      WebResearch::PageFetcher::FetchResult.new(text: text, truncated: suffix == "three")
    end

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call
    attempts = fetched.length.times.map { fetched.pop }

    assert attempts.all? { |_suffix, query| query == "example" }
    assert_equal "partial", result[:metadata][:status]
    assert_includes result[:evidence], '"content_truncated":true'
  end

  test "uses available snippets when pages cannot be fetched" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      6.times.map do |index|
        { title: index.to_s, url: "https://example.com/#{index}", snippet: "Snippet #{index}", published_at: nil }
      end
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |*, **|
      raise WebResearch::PageFetcher::Error, "blocked"
    end

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    refute_empty result[:metadata][:sources]
    assert result[:metadata][:sources].all? { |source| source[:content_truncated] }
    assert result[:metadata][:sources].all? { |source| source[:extraction_status] == "snippet" }
  end

  test "uses available snippets when fetches are cancelled at the deadline" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      %w[one two three].map do |suffix|
        { title: suffix, url: "https://example.com/#{suffix}", snippet: "Snippet for #{suffix}", published_at: nil }
      end
    end
    blocked = Queue.new
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |url, **| blocked.pop }

    result = nil
    stub_const(WebResearch::Service, :RESEARCH_DEADLINE_SECONDS, 1) do
      result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call
    end

    assert_not_nil result[:evidence]
    assert_equal "partial", result[:metadata][:status]
    assert result[:metadata][:sources].all? { |source| source[:extraction_status] == "snippet" }
    assert_includes result[:metadata][:sources].map { |source| source[:url] }, "https://example.com/one"
  end

  test "keeps complete status when grace period cancels surplus candidates" do
    urls = %w[a b c d e].map { |suffix| "https://example.com/#{suffix}" }
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      urls.map { |url| { title: url.split("/").last, url: url, snippet: "", published_at: nil } }
    end
    blocked = Queue.new
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |url, **|
      url == urls.last ? blocked.pop : "Full page text for #{url}"
    end

    result = nil
    stub_const(WebResearch::Service, :FETCH_GRACE_SECONDS, 0.2) do
      result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call
    end

    assert_equal "complete", result[:metadata][:status]
    assert_equal 4, result[:metadata][:sources].length
    assert result[:metadata][:sources].all? { |source| source[:extraction_status] == "full" }
    refute_includes result[:metadata][:sources].map { |source| source[:url] }, urls.last
  end

  test "preserves extraction metadata for thin and substantive pages" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      %w[one two three four].map do |suffix|
        { title: suffix, url: "https://example.com/#{suffix}", snippet: "", published_at: nil }
      end
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |url, **_options|
      suffix = URI(url).path.delete_prefix("/")
      text = suffix == "one" ? "Title only" : ("Substantive #{suffix} content. " * 12)
      WebResearch::PageFetcher::FetchResult.new(text: text, truncated: false)
    end

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    refute_empty result[:metadata][:sources]
    result[:metadata][:sources].each do |source|
      assert_equal source[:title] == "one" ? "thin" : "full", source[:extraction_status]
    end
  end

  test "retains thin text as last-resort evidence with objective metadata" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      [ { title: "One", url: "https://example.com/one", snippet: "", published_at: nil } ]
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |*_args, **_options|
      WebResearch::PageFetcher::FetchResult.new(text: "Useful short notice", truncated: false)
    end

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call
    source = result[:metadata][:sources].first

    assert_equal "partial", result[:metadata][:status]
    assert_equal "thin", source[:extraction_status]
    assert_equal "Useful short notice".length, source[:content_chars]
    assert_includes result[:evidence], '"extraction_status":"thin"'
    assert_includes result[:evidence], '"content":"Useful short notice"'
  end

  test "prefers a longer provider snippet to a thin page shell" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    snippet = "Provider snippet with more useful context than the page title."
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      [ { title: "One", url: "https://example.com/one", snippet: snippet, published_at: nil } ]
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |*_args, **_options|
      WebResearch::PageFetcher::FetchResult.new(text: "Title", truncated: false)
    end

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call
    source = result[:metadata][:sources].first

    assert_equal "snippet", source[:extraction_status]
    assert_equal snippet.length, source[:content_chars]
    assert_includes result[:evidence], '"content_type":"search_snippet"'
    assert_includes result[:evidence], snippet
  end

  private

  def capture_rails_logs
    original_logger = Rails.logger
    io = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original_logger
  end
end
