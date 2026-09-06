require "test_helper"

class WebResearch::PageFetcherTest < ActiveSupport::TestCase
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
end
