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
    fetcher.define_singleton_method(:validate_target!) { |*_args| true }
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
    fetcher.define_singleton_method(:validate_target!) { |*_args| true }
    fetcher.define_singleton_method(:fetch) { |_url, **| "Useful source text" }

    log_output = capture_rails_logs do
      WebResearch::Service.new(request: request, adapter: adapter, fetcher: fetcher).call
    end

    assert_includes log_output, 'event=search_started data={"query":"example query"}'
    assert_includes log_output, "https://example.com/one"
    refute_includes log_output, "tracking=secret"
    assert_includes log_output, 'event=page_extract_ready'
    assert_includes log_output, "Useful source text"
    assert_includes log_output, 'event=research_completed'
    assert_includes log_output, 'event=research_latency'
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
