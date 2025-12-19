module Api
  class MessagesController < ApplicationController
    before_action :authenticate_api_user!

    def create
      conversation = Conversation.find(params[:conversation_id])
      safe_model_code = params[:model_code] if AI_MODELS.map{|m| m['id']}.include?(params[:model_code])
      safe_model_code ||= conversation.model_code
      conversation.update!(model_code: safe_model_code) if conversation.model_code != safe_model_code
      conversation.entitle(params[:content]) if conversation.messages.empty?

      user_message = conversation.messages.create!(
        role: "user",
        content: params[:content]
      )

      messages = conversation.messages
       .order(:created_at)
       .map { |m| { role: m.role, content: m.content } }

      result = OpenaiChatService.call(
        messages: messages,
        model: safe_model_code
      )

      if result[:error]
        conversation.messages.create!(role: "assistant", content: "Error: #{result[:error]}")
        render json: { error: result[:error] }, status: :bad_gateway
      else
        reply = result[:reply]
        conversation.messages.create!(role: "assistant", content: reply)
        render json: { reply: reply }
      end
    end
  end
end
