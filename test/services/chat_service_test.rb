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

  # single pass streaming — reasoning routing
  test "single pass routes reasoning chunks to thinking and emits phase_change before the answer" do
    service = ChatService.new(messages: MESSAGES, model: "local-llama", use_persona: false, use_scaffolding: false, stream: true, max_tokens: nil)
    adapter = service.instance_variable_get(:@adapter)
    fake_stream = ->(**_kwargs, &blk) {
      blk.call("thinking ", :reasoning)
      blk.call("more ", :reasoning)
      blk.call("answer", :content)
      { tokens: { total_tokens: 5 }, stats: {} }
    }
    events = []
    adapter.stub(:chat, fake_stream) do
      service.call { |chunk, phase| events << [ phase, chunk ] }
    end
    assert_equal [ :thinking, "thinking " ], events[0]
    assert_equal [ :thinking, "more " ], events[1]
    assert_equal [ :phase_change, nil ], events[2]
    assert_equal [ :response, "answer" ], events[3]
  end

  test "single pass treats untagged chunks as response with no phase_change" do
    service = ChatService.new(messages: MESSAGES, model: "gpt-4o", use_persona: false, use_scaffolding: false, stream: true, max_tokens: nil)
    adapter = service.instance_variable_get(:@adapter)
    # Non-llama adapters yield a single arg (kind is nil).
    fake_stream = ->(**_kwargs, &blk) {
      blk.call("hello")
      blk.call(" world")
      { tokens: { total_tokens: 2 }, stats: {} }
    }
    events = []
    adapter.stub(:chat, fake_stream) do
      service.call { |chunk, phase| events << [ phase, chunk ] }
    end
    assert_equal [ [ :response, "hello" ], [ :response, " world" ] ], events
    refute events.any? { |phase, _| phase == :phase_change }
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

  # persona
  test "use_persona: false produces no system message" do
    captured = nil
    service = ChatService.new(messages: MESSAGES, model: "gpt-4o", use_persona: false, use_scaffolding: false, stream: false, max_tokens: nil)
    adapter = service.instance_variable_get(:@adapter)
    adapter.stub(:chat, ->(**kwargs) { captured = kwargs[:messages]; FAKE_RESPONSE }) do
      result = service.call
      assert_nil captured.find { |m| m[:role] == "system" }
      assert_nil result[:persona_version]
    end
  end

  test "use_persona: true with persona_id loads that persona's content as system message" do
    persona = Persona.find("persona1")
    persona.stub(:load, { content: "PERSONA CONTENT", version: "abcd1234" }) do
      captured = nil
      service = ChatService.new(messages: MESSAGES, model: "claude-sonnet-4-5", use_persona: true, use_scaffolding: false, stream: false, max_tokens: nil, persona_id: "persona1")
      adapter = service.instance_variable_get(:@adapter)
      adapter.stub(:chat, ->(**kwargs) { captured = kwargs[:messages]; FAKE_RESPONSE }) do
        result = service.call
        system_msg = captured.find { |m| m[:role] == "system" }
        assert_not_nil system_msg
        assert_equal "PERSONA CONTENT", system_msg[:content]
        assert_equal "abcd1234", result[:persona_version]
      end
    end
  end

  test "persona_id selection routes to the right persona's content" do
    persona = Persona.find("persona2-condensed")
    persona.stub(:load, { content: "CONDENSED VARIANT CONTENT", version: "11111111" }) do
      captured = nil
      service = ChatService.new(messages: MESSAGES, model: "local-llama", use_persona: true, use_scaffolding: false, stream: false, max_tokens: nil, persona_id: "persona2-condensed")
      adapter = service.instance_variable_get(:@adapter)
      adapter.stub(:chat, ->(**kwargs) { captured = kwargs[:messages]; FAKE_RESPONSE }) do
        service.call
        system_msg = captured.find { |m| m[:role] == "system" }
        assert_equal "CONDENSED VARIANT CONTENT", system_msg[:content]
      end
    end
  end

  test "unknown persona_id falls back to default and logs a warning" do
    captured = nil
    service = ChatService.new(messages: MESSAGES, model: "gpt-4o", use_persona: true, use_scaffolding: false, stream: false, max_tokens: nil, persona_id: "does-not-exist")
    adapter = service.instance_variable_get(:@adapter)
    adapter.stub(:chat, ->(**kwargs) { captured = kwargs[:messages]; FAKE_RESPONSE }) do
      log_output = capture_rails_logs { service.call }
      assert_includes log_output, "persona_id=\"does-not-exist\" not found"
      system_msg = captured.find { |m| m[:role] == "system" }
      assert_not_nil system_msg, "should still load the default persona"
    end
  end

  test "missing persona file results in nil persona_version and no system message" do
    persona = Persona.find("persona1")
    persona.stub(:load, nil) do
      captured = nil
      service = ChatService.new(messages: MESSAGES, model: "gpt-4o", use_persona: true, use_scaffolding: false, stream: false, max_tokens: nil, persona_id: "persona1")
      adapter = service.instance_variable_get(:@adapter)
      adapter.stub(:chat, ->(**kwargs) { captured = kwargs[:messages]; FAKE_RESPONSE }) do
        result = service.call
        assert_nil captured.find { |m| m[:role] == "system" }
        assert_nil result[:persona_version]
      end
    end
  end

  test "use_persona: true with no persona_id uses default persona" do
    captured = nil
    service = ChatService.new(messages: MESSAGES, model: "gpt-4o", use_persona: true, use_scaffolding: false, stream: false, max_tokens: nil, persona_id: nil)
    adapter = service.instance_variable_get(:@adapter)
    adapter.stub(:chat, ->(**kwargs) { captured = kwargs[:messages]; FAKE_RESPONSE }) do
      service.call
      system_msg = captured.find { |m| m[:role] == "system" }
      assert_not_nil system_msg, "default persona should load when persona_id is nil"
    end
  end

  test "two-pass prefill is just the planning output and a separator, no stylized intro" do
    planning_response = { content: "my analysis", tokens: { prompt_tokens: 8, completion_tokens: 4, total_tokens: 12 } }
    execution_response = { content: "my reply", tokens: { prompt_tokens: 10, completion_tokens: 6, total_tokens: 16 } }

    execution_captured = nil
    service = ChatService.new(messages: MESSAGES, model: "gpt-4o", use_persona: false, use_scaffolding: true, stream: false, max_tokens: nil)
    adapter = service.instance_variable_get(:@adapter)

    call_count = 0
    adapter.stub(:chat, ->(**kwargs) {
      if call_count == 0
        call_count += 1
        planning_response
      else
        execution_captured = kwargs[:messages]
        execution_response
      end
    }) do
      service.call
    end

    assistant_prefill = execution_captured.find { |m| m[:role] == "assistant" }
    assert_not_nil assistant_prefill
    refute_includes assistant_prefill[:content], "Based on this analysis"
    assert_includes assistant_prefill[:content], "my analysis"
    assert_includes assistant_prefill[:content], "---"
  end

  test "persona_version is recorded in two-pass result" do
    planning_response = { content: "my analysis", tokens: { prompt_tokens: 8, completion_tokens: 4, total_tokens: 12 } }
    execution_response = { content: "my reply", tokens: { prompt_tokens: 10, completion_tokens: 6, total_tokens: 16 } }

    service = ChatService.new(messages: MESSAGES, model: "claude-sonnet-4-5", use_persona: true, use_scaffolding: true, stream: false, max_tokens: nil, persona_id: "persona1")
    responses = [ planning_response, execution_response ]
    adapter = service.instance_variable_get(:@adapter)

    call_count = 0
    adapter.stub(:chat, ->(**_kwargs) { responses[call_count].tap { call_count += 1 } }) do
      result = service.call
      assert_match(/\A[0-9a-f]{8}\z/, result[:persona_version])
    end
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
