module Api
  class ChatsController < ApplicationController
    before_action :authenticate_with_jwt!

    def create
      conversation = Conversation.find(params[:conversation_id])

      user_message = conversation.messages.create!(
        role: "user",
        content: params[:content]
      )

      messages = conversation.messages.order(:created_at).map { |m| { role: m.role, content: m.content } }

      result = OpenaiChatService.call(messages: messages, model: ENV["DEFAULT_MODEL"])

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
