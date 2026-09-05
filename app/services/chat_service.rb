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

  RESEARCH_TOOL = {
    type: "function",
    function: {
      name: "research_web",
      description: "Research current or niche information on the web before answering.",
      parameters: {
        type: "object",
        properties: {
          queries: { type: "array", items: { type: "string" }, maxItems: 2 },
          urls: { type: "array", items: { type: "string" }, maxItems: 3 }
        },
        additionalProperties: false
      }
    }
  }.freeze

  def self.call(messages:, model: nil, use_persona: false, use_scaffolding: false, stream: false, max_tokens: nil, rag_context: nil, persona_id: nil, skills: [], web_search_mode: "off", log_stats: true, &block)
    new(messages: messages, model: model, use_persona: use_persona, use_scaffolding: use_scaffolding, stream: stream, max_tokens: max_tokens, rag_context: rag_context, persona_id: persona_id, skills: skills, web_search_mode: web_search_mode, log_stats: log_stats).call(&block)
  end

  # skills is an array of { id:, name:, content:, version: } hashes resolved by the caller.
  def initialize(messages:, model:, use_persona:, use_scaffolding:, stream:, max_tokens:, rag_context: nil, persona_id: nil, skills: [], web_search_mode: "off", log_stats: true)
    @messages = messages
    @model_id = model.presence || FALLBACK_MODEL
    @use_persona = use_persona
    @use_scaffolding = use_scaffolding
    @stream = stream
    @max_tokens = max_tokens || DEFAULT_MAX_TOKENS
    @rag_context = rag_context.presence
    @persona_id = persona_id.presence
    @skills = skills.presence || []
    @web_search_mode = web_search_mode.to_s
    @log_stats = log_stats
    @adapter = select_adapter(@model_id)
  end

  def call(&block)
    unless enabled?
      return dev_mode_response(&block)
    end

    Rails.logger.info("ChatService: using #{@adapter.class.name} for model #{@model_id}")

    research = perform_web_research(&block)
    @web_evidence = research[:evidence]
    @web_search_data = research[:metadata]

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
    messages_to_send = prepend_system(@messages, build_system_content(persona))
    messages_to_send = inject_external_context(messages_to_send)

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
        persona_version: persona&.dig(:version),
        skill_versions: skill_versions,
        web_search_data: @web_search_data
      }
    else
      response = @adapter.chat(messages: messages_to_send, stream: false, max_tokens: @max_tokens)
      {
        reply: response[:content],
        thinking: response[:reasoning],
        tokens: response[:tokens],
        stats: response[:stats],
        persona_version: persona&.dig(:version),
        skill_versions: skill_versions,
        web_search_data: @web_search_data
      }
    end
  end

  def two_pass_call(&block)
    persona = load_persona
    system_content = build_system_content(persona)

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
    # System message stays clean (persona and skills only). Planning output goes in the
    # assistant role as a prior turn. The model continues from its own analysis
    # into the final response without a stylized intro that would compete
    # with the persona voice.
    prefill = "#{thinking}\n\n---\n\n"

    execution_messages = [
      *(system_content ? [ { role: "system", content: system_content } ] : []),
      *inject_external_context(@messages),
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
        persona_version: persona&.dig(:version),
        skill_versions: skill_versions,
        web_search_data: @web_search_data
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
        persona_version: persona&.dig(:version),
        skill_versions: skill_versions,
        web_search_data: @web_search_data
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

  def prepend_system(messages, content)
    return messages if content.nil?
    return messages if messages.first&.dig(:role) == "system"
    [ { role: "system", content: content } ] + messages
  end

  # Persona and skills share one system message; local models handle that better than several.
  def build_system_content(persona)
    parts = [ persona&.dig(:content), format_skills ].compact
    return nil if parts.empty?

    parts.join("\n\n")
  end

  def format_skills
    return nil if @skills.blank?

    Rails.logger.info("Skills: ids=#{@skills.map { |s| s[:id] }.inspect}")
    sections = @skills.map { |s| "### #{s[:name]}\n\n#{s[:content]}" }
    "## Skills\n\n#{sections.join("\n\n")}"
  end

  def skill_versions
    return nil if @skills.blank?

    @skills.to_h { |s| [ s[:id].to_s, s[:version] ] }
  end

  # Inject retrieved RAG context by prepending it to the content of the first
  # user message. We intentionally do NOT add a second system message: local
  # models struggle with long multi-purpose system messages (see the execution
  # pass comment above).
  def inject_external_context(messages)
    context = external_context
    return messages unless context
    first_user_idx = messages.find_index { |m| m[:role] == "user" }
    return messages unless first_user_idx

    original = messages[first_user_idx]
    updated = original.merge(content: prepend_context(original[:content], context))
    messages.each_with_index.map { |m, i| i == first_user_idx ? updated : m }
  end

  # Content is an Array when the turn carries images; the context belongs on the
  # text part, not stringified over the whole payload.
  def prepend_context(content, context)
    return "#{context}\n\n#{content}" unless content.is_a?(Array)

    text_idx = content.find_index { |part| part[:type] == "text" }
    return [ { type: "text", text: context } ] + content if text_idx.nil?

    content.each_with_index.map do |part, i|
      i == text_idx ? part.merge(text: "#{context}\n\n#{part[:text]}") : part
    end
  end

  def text_of(content)
    return content.to_s unless content.is_a?(Array)
    content.select { |part| part[:type] == "text" }.pluck(:text).join("\n\n")
  end

  def external_context
    return @rag_context unless @web_evidence
    return @web_evidence unless @rag_context

    rag_budget = 12_000
    web_budget = 12_000
    "#{truncate_context(@rag_context, rag_budget)}\n\n#{truncate_context(@web_evidence, web_budget)}"
  end

  def truncate_context(content, budget)
    return content if content.length <= budget
    if content.start_with?("[Context from your personal documents]") && content.end_with?("\n\n[/Context]")
      closing = "\n\n[/Context]"
      return "#{content[0, budget - closing.length]}#{closing}"
    end

    content[0, budget]
  end

  def perform_web_research(&block)
    return {} unless %w[auto always].include?(@web_search_mode)
    unless @adapter.is_a?(AiAdapters::LlamaAdapter)
      metadata = failed_research_metadata("Web research is available only with local llama.cpp models.")
      emit_research_event(block, :failed, metadata)
      return { metadata: metadata }
    end

    emit_research_event(block, :deciding)
    selection = @adapter.chat(
      messages: tool_selection_messages,
      stream: false,
      max_tokens: 400,
      tools: [ RESEARCH_TOOL ],
      tool_choice: @web_search_mode == "always" ? { type: "function", function: { name: "research_web" } } : "auto"
    )
    calls = selection[:tool_calls]
    return {} if calls.blank? && @web_search_mode == "auto"

    request = WebResearch::ToolRequest.parse!(tool_calls: calls, latest_user_content: latest_user_text)
    outcome = WebResearch::Service.new(request: request, on_progress: ->(stage, data) { emit_research_event(block, stage, data) }).call
    outcome
  rescue WebResearch::ToolRequest::InvalidRequest, StandardError => e
    Rails.logger.warn("WebResearch tool selection failed stage=selection error=#{e.class}: #{e.message}")
    metadata = failed_research_metadata("Web research could not be completed.")
    emit_research_event(block, :failed, metadata)
    { metadata: metadata }
  end

  def tool_selection_messages
    recent = @messages.last(8).filter_map do |message|
      text = text_of(message[:content]).strip
      { role: message[:role], content: text[0, 2_000] } if text.present?
    end
    [ { role: "system", content: "Decide whether web research is needed. Call research_web only when current or niche external evidence would materially help. Do not answer the user." }, *recent ]
  end

  def latest_user_text
    message = @messages.reverse.find { |entry| entry[:role] == "user" }
    text_of(message&.dig(:content)).to_s
  end

  def failed_research_metadata(warning)
    { status: "failed", provider: "searxng", queries: [], searched_at: Time.current.iso8601, warning: warning, sources: [] }
  end

  def emit_research_event(block, stage, data = {})
    block&.call(data.merge(stage: stage), :web_search)
  end

  def dev_mode_response(&block)
    last_content = @messages.empty? ? "" : text_of(@messages.last[:content])
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
