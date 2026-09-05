require "test_helper"

class WebResearch::ToolRequestTest < ActiveSupport::TestCase
  def tool_call(arguments)
    [ { "function" => { "name" => "research_web", "arguments" => arguments.to_json } } ]
  end

  test "accepts bounded queries and a URL explicitly supplied by the user" do
    request = WebResearch::ToolRequest.parse!(
      tool_calls: tool_call(queries: [ "latest local AI news" ], urls: [ "https://example.com/report#section" ]),
      latest_user_content: "Please check https://example.com/report#section"
    )

    assert_equal [ "latest local AI news" ], request.queries
    assert_equal [ "https://example.com/report" ], request.urls
  end

  test "rejects a direct URL not supplied by the user" do
    error = assert_raises(WebResearch::ToolRequest::InvalidRequest) do
      WebResearch::ToolRequest.parse!(
        tool_calls: tool_call(urls: [ "https://example.com/report" ]),
        latest_user_content: "Please research this topic"
      )
    end

    assert_match "not supplied", error.message
  end

  test "rejects multiple calls, unknown tools, and oversized queries" do
    assert_raises(WebResearch::ToolRequest::InvalidRequest) do
      WebResearch::ToolRequest.parse!(tool_calls: tool_call(queries: [ "one" ]) * 2, latest_user_content: "")
    end

    assert_raises(WebResearch::ToolRequest::InvalidRequest) do
      WebResearch::ToolRequest.parse!(
        tool_calls: [ { "function" => { "name" => "other", "arguments" => "{}" } } ], latest_user_content: ""
      )
    end

    assert_raises(WebResearch::ToolRequest::InvalidRequest) do
      WebResearch::ToolRequest.parse!(tool_calls: tool_call(queries: [ "x" * 241 ]), latest_user_content: "")
    end

    assert_raises(WebResearch::ToolRequest::InvalidRequest) do
      WebResearch::ToolRequest.parse!(tool_calls: tool_call(queries: [ "one" ], extra: "ignored"), latest_user_content: "")
    end
  end
end
