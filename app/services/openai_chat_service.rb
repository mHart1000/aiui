class OpenaiChatService
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

  def self.enabled?
    ENV["OPENAI_ENABLED"] != "false"
  end

  def self.call(messages:, model: nil, use_persona: false, use_scaffolding: false, stream: false, &block)
    Rails.logger.info("OpenAI model #{model || 'none'} called with #{messages.size} messages, scaffolding: #{use_scaffolding}, stream: #{stream}")
    Rails.logger.debug("Messages: #{messages.inspect}")

    unless enabled?
      return dev_mode_response(messages, stream: stream, &block)
    end

    model_id = model.presence || FALLBACK_MODEL
    client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])

    if use_scaffolding
      two_pass_call(client: client, messages: messages, model_id: model_id, use_persona: use_persona, stream: stream, &block)
    else
      single_pass_call(client: client, messages: messages, model_id: model_id, use_persona: use_persona, stream: stream, &block)
    end
  end

  private

  def self.dev_mode_response(messages, stream: false)
    last_content = messages.empty? ? "" : messages.last[:content].to_s
    response_text = "[DEV MODE] Echo: #{last_content}"

    if stream && block_given?
      # Simulate streaming in dev mode
      response_text.chars.each do |char|
        yield char, :response
        sleep 0.01  # Simulate network delay
      end
      return nil  # Streaming mode doesn't return a value
    end

    {
      reply: response_text,
      tokens: {
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0
      }
    }
  end

  def self.single_pass_call(client:, messages:, model_id:, use_persona:, stream: false)
    messages_to_send = use_persona ? prepend_persona(messages) : messages

    begin
      if stream && block_given?
        # Streaming mode
        response_chunks = []
        client.chat(
          parameters: {
            model: model_id,
            messages: messages_to_send,
            stream: proc do |chunk, _bytesize|
              content = chunk.dig("choices", 0, "delta", "content")
              if content
                response_chunks << content
                yield content, :response
              end
            end
          }
        )
        # Note: Token usage not available in streaming mode until the end
        nil  # Streaming doesn't return a value
      else
        # Non-streaming mode
        response = client.chat(
          parameters: {
            model: model_id,
            messages: messages_to_send
          }
        )

        reply = response.dig("choices", 0, "message", "content")
        tokens = extract_token_usage(response)

        { reply: reply, tokens: tokens }
      end
    rescue => e
      Rails.logger.error("OpenAI service error: #{e.class} - #{e.message}")
      raise e
    end
  end

  def self.two_pass_call(client:, messages:, model_id:, use_persona:, stream: false)
    begin
      # Pass 1: Planning
      planning_messages = [
        { role: "system", content: PLANNING_PROMPT },
        *messages
      ]

      Rails.logger.info("Starting planning pass...")

      thinking = ""
      planning_tokens = nil

      if stream && block_given?
        # Stream the thinking as it's generated
        client.chat(
          parameters: {
            model: model_id,
            messages: planning_messages,
            stream: proc do |chunk, _bytesize|
              content = chunk.dig("choices", 0, "delta", "content")
              if content
                thinking += content
                yield content, :thinking
              end
            end
          }
        )
      else
        # Non-streaming planning
        planning_response = client.chat(
          parameters: {
            model: model_id,
            messages: planning_messages
          }
        )
        thinking = planning_response.dig("choices", 0, "message", "content")
        planning_tokens = extract_token_usage(planning_response)
      end

      Rails.logger.debug("Planning complete. Length: #{thinking.length}")

      # Pass 2: Final response using the plan
      persona_content = use_persona ? File.read(PERSONA_PATH) : nil

      execution_system_message = if persona_content
        # Combine persona with planning context
        "#{persona_content}\n\n---\n\n# Your Planning Analysis\n\n#{thinking}\n\n---\n\nNow provide your final response based on this analysis."
      else
        "Here is your planning analysis:\n\n#{thinking}\n\nNow provide your final response based on this analysis."
      end

      execution_messages = [
        { role: "system", content: execution_system_message },
        *messages
      ]

      Rails.logger.info("Starting execution pass...")

      reply = ""
      execution_tokens = nil

      if stream && block_given?
        # Stream the response as it's generated
        client.chat(
          parameters: {
            model: model_id,
            messages: execution_messages,
            stream: proc do |chunk, _bytesize|
              content = chunk.dig("choices", 0, "delta", "content")
              if content
                reply += content
                yield content, :response
              end
            end
          }
        )
        # Return accumulated data for storage
        { reply: reply, thinking: thinking }
      else
        # Non-streaming execution
        execution_response = client.chat(
          parameters: {
            model: model_id,
            messages: execution_messages
          }
        )

        reply = execution_response.dig("choices", 0, "message", "content")
        execution_tokens = extract_token_usage(execution_response)
        Rails.logger.debug("Execution complete. Tokens: #{execution_tokens}")

        # Aggregate token counts
        total_tokens = {
          planning: planning_tokens,
          execution: execution_tokens,
          total: planning_tokens[:total_tokens] + execution_tokens[:total_tokens]
        }

        {
          reply: reply,
          thinking: thinking,
          tokens: total_tokens
        }
      end
    rescue => e
      Rails.logger.error("OpenAI service error: #{e.class} - #{e.message}")
      raise e
    end
  end

  def self.extract_token_usage(response)
    usage = response.dig("usage") || {}
    {
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0
    }
  end

  def self.prepend_persona(messages)
    return messages if messages.first&.dig(:role) == "system"

    persona_content = File.read(PERSONA_PATH)
    [ { role: "system", content: persona_content } ] + messages
  end
end
