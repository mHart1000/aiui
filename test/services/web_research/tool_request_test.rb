require "test_helper"

class WebResearch::ToolRequestTest < ActiveSupport::TestCase
  def tool_call(arguments)
    [ { "function" => { "name" => "research_web", "arguments" => arguments.to_json } } ]
  end

  test "accepts bounded queries and a URL explicitly supplied by the user" do
    request = WebResearch::ToolRequest.parse!(
      tool_calls: tool_call(queries: [ "latest local AI news" ], urls: [ "https://example.com/report#section" ]),
      authorized_user_content: "Please check https://example.com/report#section"
    )

    assert_equal [ "latest local AI news" ], request.queries
    assert_equal [ "https://example.com/report" ], request.urls
  end

  test "authorizes a direct URL found anywhere in the authorized user content" do
    request = WebResearch::ToolRequest.parse!(
      tool_calls: tool_call(urls: [ "https://example.com/old" ]),
      authorized_user_content: "First turn: check https://example.com/old\nSecond turn: compare it now"
    )

    assert_equal [ "https://example.com/old" ], request.urls
  end

  test "rejects a direct URL not supplied by the user" do
    error = assert_raises(WebResearch::ToolRequest::InvalidRequest) do
      WebResearch::ToolRequest.parse!(
        tool_calls: tool_call(urls: [ "https://example.com/report" ]),
        authorized_user_content: "Please research this topic"
      )
    end

    assert_match "not supplied", error.message
  end

  test "rejects multiple calls, unknown tools, and oversized queries" do
    assert_raises(WebResearch::ToolRequest::InvalidRequest) do
      WebResearch::ToolRequest.parse!(tool_calls: tool_call(queries: [ "one" ]) * 2, authorized_user_content: "")
    end

    assert_raises(WebResearch::ToolRequest::InvalidRequest) do
      WebResearch::ToolRequest.parse!(
        tool_calls: [ { "function" => { "name" => "other", "arguments" => "{}" } } ], authorized_user_content: ""
      )
    end

    assert_raises(WebResearch::ToolRequest::InvalidRequest) do
      WebResearch::ToolRequest.parse!(tool_calls: tool_call(queries: [ "x" * 241 ]), authorized_user_content: "")
    end

    assert_raises(WebResearch::ToolRequest::InvalidRequest) do
      WebResearch::ToolRequest.parse!(tool_calls: tool_call(queries: [ "one" ], extra: "ignored"), authorized_user_content: "")
    end
  end

  test "rejects unsafe direct URL forms" do
    unsafe_urls = [
      "ftp://example.com/file",
      "https://user:password@example.com/private",
      "https://example.com:8443/article",
      "//example.com/article",
      "/relative/article"
    ]

    unsafe_urls.each do |url|
      assert_raises(WebResearch::ToolRequest::InvalidRequest, url) do
        WebResearch::ToolRequest.parse!(tool_calls: tool_call(urls: [ url ]), authorized_user_content: "Check #{url}")
      end
    end
  end

  test "rejects malformed, empty, excessive, and control-character queries" do
    invalid_arguments = [
      { queries: "not an array" },
      { queries: [] },
      { queries: [ "one", "two", "three" ] },
      { queries: [ "line\nbreak" ] },
      { queries: [ 123 ] },
      { urls: [ "https://one.example", "https://two.example", "https://three.example", "https://four.example" ] }
    ]

    invalid_arguments.each do |arguments|
      assert_raises(WebResearch::ToolRequest::InvalidRequest, arguments.inspect) do
        WebResearch::ToolRequest.parse!(tool_calls: tool_call(arguments), authorized_user_content: arguments.values.flatten.join(" "))
      end
    end

    malformed_call = [ { "function" => { "name" => "research_web", "arguments" => "{" } } ]
    assert_raises(WebResearch::ToolRequest::InvalidRequest) do
      WebResearch::ToolRequest.parse!(tool_calls: malformed_call, authorized_user_content: "")
    end
  end
end
