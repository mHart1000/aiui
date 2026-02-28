class ChatService
  FALLBACK_MODEL = "gpt-4o-2024-08-06"
  PERSONA_PATH = Rails.root.join("persona", "persona1.md")

  PLANNING_PROMPT = <<~PROMPT
    Analyze the user's request and create a structured plan:

    1. Core Intent: What is the user actually asking?
    2. Ambiguities: What details are unclear or missing?
    3. Context Check: What relevant information from conversation history applies?
    4. Assumptions: What assumptions need validation?
    5. Clarifications Needed: What questions should be asked (if any)?
    6. Response Strategy: If answerable, how should the response be structured?

    If clarification is needed, state that clearly. Otherwise, provide a detailed plan.
  PROMPT

  def self.call(messages:, model: nil, use_persona: false, use_scaffolding: false, stream: false, &block)
    new(messages: messages, model: model, use_persona: use_persona, use_scaffolding: use_scaffolding, stream: stream).call(&block)
  end

  def initialize(messages:, model:, use_persona:, use_scaffolding:, stream:)
    @messages = messages
    @model_id = model.presence || FALLBACK_MODEL
    @use_persona = use_persona
    @use_scaffolding = use_scaffolding
    @stream = stream
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
    elsif model_id.downcase.include?("llama") || model_id.downcase.include?("local")
      AiAdapters::LlamaAdapter.new(model: model_id)
    else
      AiAdapters::OpenaiAdapter.new(model: model_id)
    end
  end

  def single_pass_call(&block)
    messages_to_send = @use_persona ? prepend_persona(@messages) : @messages

    if @stream && block_given?
      response_chunks = []
      @adapter.chat(messages: messages_to_send, stream: true) do |content|
        response_chunks << content
        yield content, :response
      end
      nil
    else
      response = @adapter.chat(messages: messages_to_send, stream: false)
      { reply: response[:content], tokens: response[:tokens] }
    end
  end

  def two_pass_call(&block)
    # Pass 1: Planning
    planning_messages = [
      { role: "system", content: PLANNING_PROMPT },
      *@messages
    ]

    thinking = ""
    planning_tokens = nil

    Rails.logger.info("Starting planning pass...")

    if @stream && block_given?
      @adapter.chat(messages: planning_messages, stream: true) do |content|
        thinking += content
        yield content, :thinking
      end
    else
      response = @adapter.chat(messages: planning_messages, stream: false)
      thinking = response[:content]
      planning_tokens = response[:tokens]
    end

    # Pass 2: Execution
    persona_content = @use_persona ? File.read(PERSONA_PATH) : nil

    execution_system_message = if persona_content
      "#{persona_content}\n\n---\n\n# Your Planning Analysis\n\n#{thinking}\n\n---\n\nNow provide your final response based on this analysis."
    else
      "Here is your planning analysis:\n\n#{thinking}\n\nNow provide your final response based on this analysis."
    end

    execution_messages = [
      { role: "system", content: execution_system_message },
      *@messages
    ]

    Rails.logger.info("Starting execution pass...")

    if @stream && block_given?
      reply = ""
      @adapter.chat(messages: execution_messages, stream: true) do |content|
        reply += content
        yield content, :response
      end
      { reply: reply, thinking: thinking }
    else
      response = @adapter.chat(messages: execution_messages, stream: false)
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
