require "test_helper"

class ChatServiceTest < ActiveSupport::TestCase
  MESSAGES = [ { role: "user", content: "Hello" } ].freeze
  FAKE_RESPONSE = { content: "Hi there", tokens: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }.freeze

  # adapter routing
  test "selects AnthropicAdapter for claude models" do
    service = ChatService.new(messages: MESSAGES, model: "claude-sonnet-4-5", use_persona: false, use_scaffolding: false, stream: false, max_tokens: nil)
    assert_instance_of AiAdapters::AnthropicAdapter, service.instance_variable_get(:@adapter)
  end

  test "selects GeminiAdapter for gemini models" do
    service = ChatService.new(messages: MESSAGES, model: "gemini-2.0-flash", use_persona: false, use_scaffolding: false, stream: false, max_tokens: nil)
    assert_instance_of AiAdapters::GeminiAdapter, service.instance_variable_get(:@adapter)
  end

  test "selects LlamaAdapter for local-llama model" do
    service = ChatService.new(messages: MESSAGES, model: "local-llama", use_persona: false, use_scaffolding: false, stream: false, max_tokens: nil)
    assert_instance_of AiAdapters::LlamaAdapter, service.instance_variable_get(:@adapter)
  end

  test "selects OpenaiAdapter for gpt models" do
    service = ChatService.new(messages: MESSAGES, model: "gpt-4o", use_persona: false, use_scaffolding: false, stream: false, max_tokens: nil)
    assert_instance_of AiAdapters::OpenaiAdapter, service.instance_variable_get(:@adapter)
  end

  # dev mode
  test "returns echo response when AI_ENABLED is false" do
    with_env("AI_ENABLED" => "false") do
      result = ChatService.call(messages: MESSAGES, model: "gpt-4o")
      assert_equal "[DEV MODE] Echo: Hello", result[:reply]
    end
  end

  # single pass
  test "single pass returns reply and tokens from adapter" do
    service = ChatService.new(messages: MESSAGES, model: "gpt-4o", use_persona: false, use_scaffolding: false, stream: false, max_tokens: nil)
    service.instance_variable_get(:@adapter).stub(:chat, FAKE_RESPONSE) do
      result = service.call
      assert_equal "Hi there", result[:reply]
      assert_equal 15, result[:tokens][:total_tokens]
    end
  end

  # two pass
  test "two pass returns reply, thinking, and combined tokens" do
    planning_response = { content: "my analysis", tokens: { prompt_tokens: 8, completion_tokens: 4, total_tokens: 12 } }
    execution_response = { content: "my reply", tokens: { prompt_tokens: 10, completion_tokens: 6, total_tokens: 16 } }

    service = ChatService.new(messages: MESSAGES, model: "gpt-4o", use_persona: false, use_scaffolding: true, stream: false, max_tokens: nil)
    responses = [ planning_response, execution_response ]
    adapter = service.instance_variable_get(:@adapter)

    call_count = 0
    adapter.stub(:chat, ->(**_kwargs) { responses[call_count].tap { call_count += 1 } }) do
      result = service.call
      assert_equal "my reply", result[:reply]
      assert_equal "my analysis", result[:thinking]
      assert_equal 28, result[:tokens][:total]
    end
  end
end
