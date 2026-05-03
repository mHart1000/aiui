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

  test "selects OpenrouterAdapter for openrouter/ prefixed models" do
    service = ChatService.new(messages: MESSAGES, model: "openrouter/meta-llama/llama-3.3-70b-instruct", use_persona: false, use_scaffolding: false, stream: false, max_tokens: nil)
    assert_instance_of AiAdapters::OpenrouterAdapter, service.instance_variable_get(:@adapter)
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

  # rag injection
  test "rag_context is prepended to first user message in single pass" do
    captured = nil
    service = ChatService.new(
      messages: [ { role: "user", content: "What is my favorite food?" } ],
      model: "gpt-4o",
      use_persona: false,
      use_scaffolding: false,
      stream: false,
      max_tokens: nil,
      rag_context: "[Context]\nfavorite food is sushi\n[/Context]"
    )
    adapter = service.instance_variable_get(:@adapter)
    adapter.stub(:chat, ->(**kwargs) { captured = kwargs[:messages]; FAKE_RESPONSE }) do
      service.call
    end

    user_msg = captured.find { |m| m[:role] == "user" }
    assert_includes user_msg[:content], "[Context]"
    assert_includes user_msg[:content], "favorite food is sushi"
    assert_includes user_msg[:content], "What is my favorite food?"
    assert user_msg[:content].start_with?("[Context]"), "RAG block should be prepended before the original question"
  end

  test "rag_context is injected only on execution pass in two-pass mode" do
    planning_captured = nil
    execution_captured = nil
    planning_response = { content: "analysis", tokens: { prompt_tokens: 5, completion_tokens: 3, total_tokens: 8 } }
    execution_response = { content: "reply", tokens: { prompt_tokens: 5, completion_tokens: 3, total_tokens: 8 } }

    service = ChatService.new(
      messages: [ { role: "user", content: "original question" } ],
      model: "gpt-4o",
      use_persona: false,
      use_scaffolding: true,
      stream: false,
      max_tokens: nil,
      rag_context: "[Context]\nretrieved fact\n[/Context]"
    )
    adapter = service.instance_variable_get(:@adapter)

    call_count = 0
    adapter.stub(:chat, ->(**kwargs) {
      if call_count == 0
        planning_captured = kwargs[:messages]
        call_count += 1
        planning_response
      else
        execution_captured = kwargs[:messages]
        execution_response
      end
    }) do
      service.call
    end

    planning_user = planning_captured.find { |m| m[:role] == "user" }
    refute_includes planning_user[:content], "[Context]", "planning pass should not see RAG context"

    execution_user = execution_captured.find { |m| m[:role] == "user" }
    assert_includes execution_user[:content], "[Context]"
    assert_includes execution_user[:content], "retrieved fact"
  end

  test "nil rag_context is a no-op" do
    captured = nil
    service = ChatService.new(
      messages: [ { role: "user", content: "hello" } ],
      model: "gpt-4o",
      use_persona: false,
      use_scaffolding: false,
      stream: false,
      max_tokens: nil,
      rag_context: nil
    )
    adapter = service.instance_variable_get(:@adapter)
    adapter.stub(:chat, ->(**kwargs) { captured = kwargs[:messages]; FAKE_RESPONSE }) do
      service.call
    end

    user_msg = captured.find { |m| m[:role] == "user" }
    assert_equal "hello", user_msg[:content]
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
