module Api
  class ChatController < ApplicationController
    def create
      message = params[:message]

      if message.blank?
        render json: { error: "message param required" }, status: :bad_request
        return
      end

      response = OpenaiChatService.call(message)

      if response[:error]
        render json: response, status: :unprocessable_entity
      else
        render json: { reply: response[:reply] }
      end
    end
  end
end
