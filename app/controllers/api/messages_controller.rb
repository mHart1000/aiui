module Api
  class MessagesController < ApplicationController
    before_action :authenticate_api_user!
    include ActionController::Live

    def create
      conversation = Conversation.find(params[:conversation_id])
      safe_model_code = conversation.apply_model_code(params[:model_code])
      conversation.messages.create!(role: "user", content: params[:content])

      current_api_user.reload
      rag_context = fetch_rag_context(conversation, params[:content])
      result = ChatService.call(
        messages: conversation.messages_for_ai,
        model: safe_model_code,
        use_persona: current_api_user.use_persona,
        persona_id: current_api_user.persona_id,
        use_scaffolding: current_api_user.use_scaffolding,
        rag_context: rag_context
      )

      if result[:error]
        conversation.messages.create!(role: "assistant", content: "Error: #{result[:error]}")
        render json: { error: result[:error] }, status: :bad_gateway
      else
        conversation.add_assistant_message(
          reply: result[:reply],
          thinking: result[:thinking],
          tokens: result[:tokens],
          stats: result[:stats],
          persona_version: result[:persona_version]
        )
        conversation.entitle_async(params[:content])

        render json: {
          reply: result[:reply],
          thinking: result[:thinking],
          tokens: result[:tokens],
          generation_ms: result[:stats]&.dig(:elapsed_ms),
          tokens_per_second: result[:stats]&.dig(:tokens_per_second)
        }
      end
    end

    def update
      # edit user message
      conversation = current_api_user.conversations.find(params[:conversation_id])
      message = conversation.messages.find(params[:id])

      conversation.messages.where("created_at > ?", message.created_at).destroy_all

      message.update!(content: params[:content])
      render json: { message: message }
    end

    def create_streaming
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"  # Disable nginx buffering

      conversation = current_api_user.conversations.find(params[:conversation_id])
      safe_model_code = conversation.apply_model_code(params[:model_code])

      if params[:regenerating]
        last_msg = conversation.messages.order(:created_at).last
        last_msg.destroy if last_msg&.role == "assistant"
      else
        conversation.messages.create!(role: "user", content: params[:content])
      end

      thinking_accumulator = ""
      reply_accumulator = ""
      client_disconnected = false

      current_api_user.reload
      rag_context = fetch_rag_context(conversation, params[:content])
      # Stream the response
      begin
        stream_result = ChatService.call(
          messages: conversation.messages_for_ai,
          model: safe_model_code,
          use_persona: current_api_user.use_persona,
          persona_id: current_api_user.persona_id,
          use_scaffolding: current_api_user.use_scaffolding,
          stream: true,
          rag_context: rag_context
        ) do |chunk, phase|
          if phase == :thinking
            thinking_accumulator += chunk
          elsif phase == :response
            reply_accumulator += chunk
          end

          # Send event to client
          event_data = if phase == :phase_change
            { type: "phase_change", phase: "responding" }
          else
            { type: phase.to_s, content: chunk }
          end
          response.stream.write("data: #{event_data.to_json}\n\n")
        end

        # Send stats event before done so the client can attach throughput to the message
        if stream_result&.dig(:stats)
          stats_event = {
            type: "stats",
            generation_ms: stream_result[:stats][:elapsed_ms],
            tokens_per_second: stream_result[:stats][:tokens_per_second],
            total_tokens: stream_result.dig(:tokens, :total_tokens) || stream_result.dig(:tokens, :total)
          }
          response.stream.write("data: #{stats_event.to_json}\n\n")
        end

        # Send completion event
        response.stream.write("data: #{({ type: 'done' }).to_json}\n\n")
      rescue ActionController::Live::ClientDisconnected
        client_disconnected = true
        Rails.logger.warn("MessagesController: client disconnected during stream, saving accumulated content")
      ensure
        # Close the stream before doing DB work so the client gets the response immediately
        response.stream.close
      end

      # Save whatever was accumulated, even if the client disconnected mid-stream
      if reply_accumulator.present? || thinking_accumulator.present?
        conversation.add_assistant_message(
          reply: reply_accumulator,
          thinking: thinking_accumulator,
          tokens: stream_result&.dig(:tokens),
          stats: stream_result&.dig(:stats),
          persona_version: stream_result&.dig(:persona_version)
        )
        conversation.entitle_async(params[:content]) unless client_disconnected
      end
    end

    private

    def fetch_rag_context(conversation, query)
      unless conversation.rag_enabled
        Rails.logger.info("[RAG] skipped: rag_enabled is false on conversation #{conversation.id}")
        return nil
      end
      return nil if query.blank?

      Rails.logger.info("[RAG] query: #{query.to_s[0, 200]}")
      chunks = Rag::Retriever.call(user: current_api_user, query: query)
      Rails.logger.info("[RAG] retrieved #{chunks.length} chunks")
      chunks.each_with_index do |c, i|
        label = c.rag_document&.original_filename || c.rag_document&.title || "doc##{c.rag_document_id}"
        preview = c.content.to_s.gsub(/\s+/, " ")[0, 140]
        Rails.logger.info("[RAG]   #{i + 1}. #{label} chunk##{c.chunk_index}: #{preview}")
      end
      return nil if chunks.blank?

      context = Rag::ContextFormatter.format(chunks)
      Rails.logger.info("[RAG] injected context: #{context.to_s.length} chars")
      context
    rescue => e
      Rails.logger.warn("RAG retrieval failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
