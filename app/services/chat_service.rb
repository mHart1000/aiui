class ChatService
  FALLBACK_MODEL = ENV.fetch("DEFAULT_MODEL")
  PERSONA_PATH = Rails.root.join("persona", "persona1.md")
  DEFAULT_MAX_TOKENS = 16000

  PLANNING_PROMPT = <<~PROMPT
    You are in two-pass reasoning mode. This is the planning phase.

    Analyze the user's request:

    1. Core Intent: What is the user actually asking?
    2. Ambiguities: What details are unclear or missing?
    3. Context Check: What relevant information from conversation history applies?
    4. Assumptions: What assumptions need validation?
    5. Clarifications Needed: What questions should be asked (if any)?
    6. Response Strategy: If answerable, how should the response be structured?
  PROMPT

  def self.call(messages:, model: nil, use_persona: false, use_scaffolding: false, stream: false, max_tokens: nil, &block)
    new(messages: messages, model: model, use_persona: use_persona, use_scaffolding: use_scaffolding, stream: stream, max_tokens: max_tokens).call(&block)
  end

  def initialize(messages:, model:, use_persona:, use_scaffolding:, stream:, max_tokens:)
    @messages = messages
    @model_id = model.presence || FALLBACK_MODEL
    @use_persona = use_persona
    @use_scaffolding = use_scaffolding
    @stream = stream
    @max_tokens = max_tokens || DEFAULT_MAX_TOKENS
    @adapter = select_adapter(@model_id)
  end

  def call(&block)
    unless enabled?
      return dev_mode_response(&block)
    end

    Rails.logger.info("ChatService: using #{@adapter.class.name} for model #{@model_id}")

    if @use_scaffolding
      two_pass_call(&block)
    else
      single_pass_call(&block)
    end
  end

  private

  def enabled?
    ENV["AI_ENABLED"] != "false" && ENV["OPENAI_ENABLED"] != "false"
  end

  def select_adapter(model_id)
    if model_id.downcase.start_with?("gemini")
      AiAdapters::GeminiAdapter.new(model: model_id)
    elsif model_id.downcase.start_with?("claude")
      AiAdapters::AnthropicAdapter.new(model: model_id)
    elsif model_id.downcase.include?("llama") || model_id.downcase.include?("local") || model_id.downcase.end_with?(".gguf")
      AiAdapters::LlamaAdapter.new(model: model_id)
    else
      AiAdapters::OpenaiAdapter.new(model: model_id)
    end
  end

  def single_pass_call(&block)
    messages_to_send = @use_persona ? prepend_persona(@messages) : @messages

    if @stream && block_given?
      response_chunks = []
      @adapter.chat(messages: messages_to_send, stream: true, max_tokens: @max_tokens) do |content|
        response_chunks << content
        yield content, :response
      end
      nil
    else
      response = @adapter.chat(messages: messages_to_send, stream: false, max_tokens: @max_tokens)
      { reply: response[:content], tokens: response[:tokens] }
    end
  end

  def two_pass_call(&block)
    persona_content = @use_persona ? File.read(PERSONA_PATH) : nil

    # Pass 1: Planning
    # Only use planning prompt - persona during analysis can confuse the model
    planning_messages = [
      { role: "system", content: PLANNING_PROMPT },
      *@messages
    ]

    thinking = ""
    planning_tokens = nil

    Rails.logger.info("Starting planning pass...")

    if @stream && block_given?
      @adapter.chat(messages: planning_messages, stream: true, max_tokens: @max_tokens) do |content|
        thinking += content
        yield content, :thinking
      end
      yield nil, :phase_change
    else
      response = @adapter.chat(messages: planning_messages, stream: false, max_tokens: @max_tokens)
      thinking = response[:content]
      planning_tokens = response[:tokens]
    end

    # Pass 2: Execution via assistant-prefill
    # System message stays clean (just persona). Planning output goes in the
    # assistant role as a prior turn. The model continues from its own analysis
    # into the final response. This works reliably with local models that
    # struggle with long multi-purpose system messages.
    prefill = "#{thinking}\n\n---\n\nBased on this analysis, here is my response:\n\n"

    execution_messages = [
      *(persona_content ? [ { role: "system", content: persona_content } ] : []),
      *@messages,
      { role: "assistant", content: prefill }
    ]

    Rails.logger.info("Starting execution pass...")

    if @stream && block_given?
      reply = ""
      @adapter.chat(messages: execution_messages, stream: true, max_tokens: @max_tokens) do |content|
        reply += content
        yield content, :response
      end
      { reply: reply, thinking: thinking }
    else
      response = @adapter.chat(messages: execution_messages, stream: false, max_tokens: @max_tokens)
      reply = response[:content]
      execution_tokens = response[:tokens]

      total_tokens = {
        planning: planning_tokens,
        execution: execution_tokens,
        total: (planning_tokens&.dig(:total_tokens) || 0) + (execution_tokens&.dig(:total_tokens) || 0)
      }

      {
        reply: reply,
        thinking: thinking,
        tokens: total_tokens
      }
    end
  end

  def prepend_persona(messages)
    return messages if messages.first&.dig(:role) == "system"
    persona_content = File.read(PERSONA_PATH)
    [ { role: "system", content: persona_content } ] + messages
  end

  def dev_mode_response(&block)
    last_content = @messages.empty? ? "" : @messages.last[:content].to_s
    response_text = "[DEV MODE] Echo: #{last_content}"

    if @stream && block_given?
      response_text.chars.each do |char|
        yield char, :response
        sleep 0.01
      end
      return nil
    end

    {
      reply: response_text,
      tokens: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }
    }
  end
end
