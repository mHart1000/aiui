module Api
  class MessagesController < ApplicationController
    before_action :authenticate_api_user!

    def create
      conversation = Conversation.find(params[:conversation_id])

      if conversation.messages.count == 0
       result = OpenaiChatService.call(
          messages: [
            { role: "system", content: "Generate a short 3-6 word chat title in the style of an article title, based on the following user message. No punctuation." },
            { role: "user", content: params[:content] }
          ],
          model: "gpt-5-nano"
        )

        title = result[:reply].presence || params[:content][0..40]
        conversation.update!(title: title.strip)
      end

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
