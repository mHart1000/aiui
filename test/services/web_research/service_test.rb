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
    assert_includes log_output, 'event=page_extract_ready'
    assert_includes log_output, "Useful source text"
    assert_includes log_output, 'event=research_completed'
    assert_includes log_output, 'event=research_latency'
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
      suffixes = query == "primary" ? [ "one" ] : [ "two", "three" ]
      suffixes.map { |suffix| { title: suffix, url: "https://example.com/#{suffix}", snippet: "", published_at: nil } }
    end
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) { |url, **| "Text from #{url}" }

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    assert_equal [ "primary", "fallback" ], searched
    assert_equal [ "primary", "fallback" ], result[:metadata][:queries]
    assert_equal 3, result[:metadata][:sources].length
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

    assert_equal %w[one two], result[:metadata][:sources].map { |source| URI(source[:url]).path.delete_prefix("/") }
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
    assert_equal 1, result[:metadata][:sources].length
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

  test "fetches candidates concurrently and preserves candidate order" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      %w[one two three].map do |suffix|
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

    service_thread = Thread.new { WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call }
    started_urls = Timeout.timeout(1) { 3.times.map { started.pop } }
    3.times { release << true }
    result = service_thread.value

    assert_equal 3, started_urls.length
    assert_equal %w[one two three], result[:metadata][:sources].map { |source| URI(source[:url]).path.delete_prefix("/") }
  ensure
    3.times { release << true } if release
    service_thread&.join(1)
  end

  test "backfills failed initial candidates and retains three successful pages" do
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

      WebResearch::PageFetcher::FetchResult.new(text: "Text from #{suffix}", truncated: suffix == "three")
    end

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call
    attempts = 5.times.map { fetched.pop }

    assert_equal %w[one two three four five].sort, attempts.map(&:first).sort
    assert attempts.all? { |_suffix, query| query == "example" }
    assert_equal %w[three four five], result[:metadata][:sources].map { |source| URI(source[:url]).path.delete_prefix("/") }
    assert_equal [ true, false, false ], result[:metadata][:sources].map { |source| source[:content_truncated] }
    assert_equal 3, result[:metadata][:sources].length
    assert_equal "partial", result[:metadata][:status]
    assert_includes result[:evidence], '"content_truncated":true'
    refute_includes result[:evidence], "Snippet one"
  end

  test "limits page attempts and then uses available snippets" do
    request = WebResearch::ToolRequest.new({ "queries" => [ "example" ] }, latest_user_content: "")
    adapter = Object.new
    adapter.define_singleton_method(:search) do |_query, **_options|
      6.times.map do |index|
        { title: index.to_s, url: "https://example.com/#{index}", snippet: "Snippet #{index}", published_at: nil }
      end
    end
    fetched = Queue.new
    fetcher = Object.new
    fetcher.define_singleton_method(:fetch) do |url, **_options|
      fetched << url
      raise WebResearch::PageFetcher::Error, "blocked"
    end

    result = WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call

    assert_equal WebResearch::Service::MAX_FETCH_ATTEMPTS, fetched.length
    assert_equal WebResearch::Service::MAX_PAGES, result[:metadata][:sources].length
    assert result[:metadata][:sources].all? { |source| source[:content_truncated] }
    assert_not_includes result[:metadata][:sources].map { |source| source[:url] }, "https://example.com/5"
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
