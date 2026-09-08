require "test_helper"

class AiAdapters::LlamaAdapterTest < ActiveSupport::TestCase
  test "blocking chat passes template kwargs and returns the finish reason" do
    response_body = {
      choices: [ {
        finish_reason: "tool_calls",
        message: {
          content: nil,
          tool_calls: [ { id: "call-1", function: { name: "research_web", arguments: "{}" } } ]
        }
      } ],
      usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
    }.to_json
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, response_body)
    captured_payload = nil
    http = Object.new
    http.define_singleton_method(:read_timeout=) { |_value| }
    http.define_singleton_method(:request) do |request|
      captured_payload = JSON.parse(request.body)
      response
    end

    Net::HTTP.stub(:new, http) do
      result = AiAdapters::LlamaAdapter.new(model: "local-llama", log_stats: false).chat(
        messages: [ { role: "user", content: "route this" } ],
        chat_template_kwargs: { reasoning_effort: "low" },
        thinking_budget_tokens: 128,
        reasoning_budget_message: "Call the tool now.",
        id_slot: 2,
        cache_prompt: true
      )

      assert_equal({ "reasoning_effort" => "low" }, captured_payload["chat_template_kwargs"])
      assert_equal 128, captured_payload["thinking_budget_tokens"]
      assert_equal "Call the tool now.", captured_payload["reasoning_budget_message"]
      assert_equal 2, captured_payload["id_slot"]
      assert_equal true, captured_payload["cache_prompt"]
      assert_equal "tool_calls", result[:finish_reason]
      assert_equal 1, result[:tool_calls].length
    end
  end

  test "streaming chat returns and logs the final finish reason" do
    chunks = [
      "data: #{ { choices: [ { delta: { content: "Done" }, finish_reason: nil } ] }.to_json }\n\n",
      "data: #{ { choices: [ { delta: {}, finish_reason: "length" } ] }.to_json }\n\n",
      "data: #{ { choices: [], usage: { prompt_tokens: 4, completion_tokens: 2, total_tokens: 6 } }.to_json }\n\n",
      "data: [DONE]\n\n"
    ]
    response = Object.new
    response.define_singleton_method(:read_body) { |&block| chunks.each { |chunk| block.call(chunk) } }
    http = Object.new
    http.define_singleton_method(:request) { |_request, &block| block.call(response) }
    streamed = []

    log_output = capture_rails_logs do
      Net::HTTP.stub(:start, ->(*_args, &block) { block.call(http) }) do
        result = AiAdapters::LlamaAdapter.new(model: "local-llama").chat(
          messages: [ { role: "user", content: "respond" } ],
          stream: true
        ) { |chunk, kind| streamed << [ chunk, kind ] }

        assert_equal "length", result[:finish_reason]
        assert_equal 6, result.dig(:tokens, :total_tokens)
      end
    end

    assert_equal [ [ "Done", :content ] ], streamed
    assert_includes log_output, "Finish     — length"
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
