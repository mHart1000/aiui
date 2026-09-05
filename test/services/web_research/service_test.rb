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
end
