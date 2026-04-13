module Api
  class MessagesController < ApplicationController
    before_action :authenticate_api_user!
    include ActionController::Live

    def create
      conversation = Conversation.find(params[:conversation_id])
      safe_model_code = conversation.apply_model_code(params[:model_code])
      conversation.messages.create!(role: "user", content: params[:content])

      current_api_user.reload
      result = ChatService.call(
        messages: conversation.messages_for_ai,
        model: safe_model_code,
        use_persona: true,
        use_scaffolding: current_api_user.use_scaffolding
      )

      if result[:error]
        conversation.messages.create!(role: "assistant", content: "Error: #{result[:error]}")
        render json: { error: result[:error] }, status: :bad_gateway
      else
        conversation.add_assistant_message(reply: result[:reply], thinking: result[:thinking], tokens: result[:tokens])
        conversation.entitle_async(params[:content])

        render json: {
          reply: result[:reply],
          thinking: result[:thinking],
          tokens: result[:tokens]
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

      # Only create user message if not regenerating
      unless params[:regenerating]
        conversation.messages.create!(role: "user", content: params[:content])
      end

      thinking_accumulator = ""
      reply_accumulator = ""
      client_disconnected = false

      current_api_user.reload
      # Stream the response
      begin
        ChatService.call(
          messages: conversation.messages_for_ai,
          model: safe_model_code,
          use_persona: true,
          use_scaffolding: current_api_user.use_scaffolding,
          stream: true
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
        conversation.add_assistant_message(reply: reply_accumulator, thinking: thinking_accumulator, tokens: nil)
        conversation.entitle_async(params[:content]) unless client_disconnected
      end
    end
  end
end
