module Api
  class MessagesController < ApplicationController
    before_action :authenticate_api_user!
    include ActionController::Live

    def create
      conversation = Conversation.find(params[:conversation_id])
      safe_model_code = conversation.apply_model_code(params[:model_code])
      conversation.entitle_async(params[:content])
      conversation.messages.create!(role: "user", content: params[:content])

      result = ChatService.call(
        messages: conversation.messages_for_ai,
        model: safe_model_code,
        use_persona: true,
        use_scaffolding: true
      )

      if result[:error]
        conversation.messages.create!(role: "assistant", content: "Error: #{result[:error]}")
        render json: { error: result[:error] }, status: :bad_gateway
      else
        conversation.add_assistant_message(reply: result[:reply], thinking: result[:thinking], tokens: result[:tokens])

        render json: {
          reply: result[:reply],
          thinking: result[:thinking],
          tokens: result[:tokens]
        }
      end
    end

    def create_streaming
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"  # Disable nginx buffering

      begin
        conversation = current_api_user.conversations.find(params[:conversation_id])
        safe_model_code = conversation.apply_model_code(params[:model_code])
        conversation.entitle_async(params[:content])
        conversation.messages.create!(role: "user", content: params[:content])

        thinking_accumulator = ""
        reply_accumulator = ""

        # Stream the response
        ChatService.call(
          messages: conversation.messages_for_ai,
          model: safe_model_code,
          use_persona: true,
          use_scaffolding: true,
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

        # Token tracking not available in streaming mode yet
        conversation.add_assistant_message(reply: reply_accumulator, thinking: thinking_accumulator, tokens: nil)

      ensure
        response.stream.close
      end
    end
  end
end
