class ChatService
  FALLBACK_MODEL = ENV.fetch("DEFAULT_MODEL", "local-llama")
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

  def self.call(messages:, model: nil, use_persona: false, use_scaffolding: false, stream: false, max_tokens: nil, rag_context: nil, persona_id: nil, log_stats: true, &block)
    new(messages: messages, model: model, use_persona: use_persona, use_scaffolding: use_scaffolding, stream: stream, max_tokens: max_tokens, rag_context: rag_context, persona_id: persona_id, log_stats: log_stats).call(&block)
  end

  def initialize(messages:, model:, use_persona:, use_scaffolding:, stream:, max_tokens:, rag_context: nil, persona_id: nil, log_stats: true)
    @messages = messages
    @model_id = model.presence || FALLBACK_MODEL
    @use_persona = use_persona
    @use_scaffolding = use_scaffolding
    @stream = stream
    @max_tokens = max_tokens || DEFAULT_MAX_TOKENS
    @rag_context = rag_context.presence
    @persona_id = persona_id.presence
    @log_stats = log_stats
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
    if model_id.downcase.start_with?("openrouter/")
      AiAdapters::OpenrouterAdapter.new(model: model_id)
    elsif model_id.downcase.start_with?("gemini")
      AiAdapters::GeminiAdapter.new(model: model_id)
    elsif model_id.downcase.start_with?("claude")
      AiAdapters::AnthropicAdapter.new(model: model_id)
    elsif model_id.downcase.include?("llama") || model_id.downcase.include?("local") || model_id.downcase.end_with?(".gguf")
      AiAdapters::LlamaAdapter.new(model: model_id, log_stats: @log_stats)
    else
      AiAdapters::OpenaiAdapter.new(model: model_id)
    end
  end

  def single_pass_call(&block)
    persona = load_persona
    messages_to_send = prepend_persona(@messages, persona)
    messages_to_send = inject_rag_context(messages_to_send)

    if @stream && block_given?
      saw_reasoning = false
      switched_to_response = false
      adapter_result = @adapter.chat(messages: messages_to_send, stream: true, max_tokens: @max_tokens) do |chunk, kind|
        if kind == :reasoning
          saw_reasoning = true
          yield chunk, :thinking
        else
          # First answer token after a reasoning phase: flip the UI to responding.
          if saw_reasoning && !switched_to_response
            switched_to_response = true
            yield nil, :phase_change
          end
          yield chunk, :response
        end
      end
      {
        tokens: adapter_result.is_a?(Hash) ? adapter_result[:tokens] : nil,
        stats: adapter_result.is_a?(Hash) ? adapter_result[:stats] : nil,
        persona_version: persona&.dig(:version)
      }
    else
      response = @adapter.chat(messages: messages_to_send, stream: false, max_tokens: @max_tokens)
      {
        reply: response[:content],
        thinking: response[:reasoning],
        tokens: response[:tokens],
        stats: response[:stats],
        persona_version: persona&.dig(:version)
      }
    end
  end

  def two_pass_call(&block)
    persona = load_persona

    # Pass 1: Planning
    # Only use planning prompt - persona during analysis can confuse the model
    planning_messages = [
      { role: "system", content: PLANNING_PROMPT },
      *@messages
    ]

    thinking = ""
    planning_tokens = nil
    planning_stats = nil

    Rails.logger.info("Starting planning pass...")

    if @stream && block_given?
      planning_result = @adapter.chat(messages: planning_messages, stream: true, max_tokens: @max_tokens) do |content|
        thinking += content
        yield content, :thinking
      end
      if planning_result.is_a?(Hash)
        planning_tokens = planning_result[:tokens]
        planning_stats = planning_result[:stats]
      end
      yield nil, :phase_change
    else
      response = @adapter.chat(messages: planning_messages, stream: false, max_tokens: @max_tokens)
      thinking = response[:content]
      planning_tokens = response[:tokens]
      planning_stats = response[:stats]
    end

    # Pass 2: Execution via assistant-prefill
    # System message stays clean (just persona). Planning output goes in the
    # assistant role as a prior turn. The model continues from its own analysis
    # into the final response without a stylized intro that would compete
    # with the persona voice.
    prefill = "#{thinking}\n\n---\n\n"

    execution_messages = [
      *(persona ? [ { role: "system", content: persona[:content] } ] : []),
      *inject_rag_context(@messages),
      { role: "assistant", content: prefill }
    ]

    Rails.logger.info("Starting execution pass...")

    if @stream && block_given?
      reply = ""
      execution_result = @adapter.chat(messages: execution_messages, stream: true, max_tokens: @max_tokens) do |chunk, kind|
        # Native reasoning during the execution pass goes to the thinking stream,
        # never into the saved reply.
        if kind == :reasoning
          yield chunk, :thinking
        else
          reply += chunk
          yield chunk, :response
        end
      end
      execution_tokens = execution_result.is_a?(Hash) ? execution_result[:tokens] : nil
      execution_stats = execution_result.is_a?(Hash) ? execution_result[:stats] : nil

      total_tokens = combine_tokens(planning_tokens, execution_tokens)
      combined_stats = combine_stats(planning_stats, execution_stats, total_tokens)

      {
        reply: reply,
        thinking: thinking,
        tokens: total_tokens,
        stats: combined_stats,
        persona_version: persona&.dig(:version)
      }
    else
      response = @adapter.chat(messages: execution_messages, stream: false, max_tokens: @max_tokens)
      reply = response[:content]
      execution_tokens = response[:tokens]
      execution_stats = response[:stats]

      total_tokens = combine_tokens(planning_tokens, execution_tokens)
      combined_stats = combine_stats(planning_stats, execution_stats, total_tokens)

      {
        reply: reply,
        thinking: thinking,
        tokens: total_tokens,
        stats: combined_stats,
        persona_version: persona&.dig(:version)
      }
    end
  end

  def combine_tokens(planning, execution)
    return execution if planning.nil?
    return planning if execution.nil?
    {
      planning: planning,
      execution: execution,
      total: (planning[:total_tokens] || 0) + (execution[:total_tokens] || 0),
      completion_tokens: (planning[:completion_tokens] || 0) + (execution[:completion_tokens] || 0),
      prompt_tokens: (planning[:prompt_tokens] || 0) + (execution[:prompt_tokens] || 0),
      total_tokens: (planning[:total_tokens] || 0) + (execution[:total_tokens] || 0)
    }
  end

  # Sum elapsed time across the two passes and recompute tok/s from the
  # combined completion-token count. Server-reported tok/s loses meaning when
  # summed across requests, so we always mark this as "computed".
  def combine_stats(planning, execution, combined_tokens)
    return execution if planning.nil?
    return planning if execution.nil?

    elapsed_ms = (planning[:elapsed_ms] || 0) + (execution[:elapsed_ms] || 0)
    completion = combined_tokens.is_a?(Hash) ? (combined_tokens[:completion_tokens] || 0) : 0
    tps = (completion.positive? && elapsed_ms.positive?) ? (completion * 1000.0 / elapsed_ms) : nil

    { elapsed_ms: elapsed_ms, tokens_per_second: tps, tps_source: "computed" }
  end

  def load_persona
    return nil unless @use_persona

    persona = Persona.find(@persona_id) || Persona.default
    if @persona_id && persona.id != @persona_id
      Rails.logger.warn("ChatService: persona_id=#{@persona_id.inspect} not found, falling back to #{persona.id}")
    end
    return nil unless persona

    result = persona.load
    if result
      Rails.logger.info("Persona: id=#{persona.id} version=#{result[:version]}")
    else
      Rails.logger.warn("Persona: id=#{persona.id} failed to load — proceeding without persona system message")
    end
    result
  end

  def prepend_persona(messages, persona)
    return messages unless persona
    return messages if messages.first&.dig(:role) == "system"
    [ { role: "system", content: persona[:content] } ] + messages
  end

  # Inject retrieved RAG context by prepending it to the content of the first
  # user message. We intentionally do NOT add a second system message: local
  # models struggle with long multi-purpose system messages (see the execution
  # pass comment above).
  def inject_rag_context(messages)
    return messages unless @rag_context
    first_user_idx = messages.find_index { |m| m[:role] == "user" }
    return messages unless first_user_idx

    original = messages[first_user_idx]
    updated = original.merge(content: "#{@rag_context}\n\n#{original[:content]}")
    messages.each_with_index.map { |m, i| i == first_user_idx ? updated : m }
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
