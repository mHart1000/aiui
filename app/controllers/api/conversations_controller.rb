module Api
  class ConversationsController < ApplicationController
    before_action :authenticate_api_user!
    respond_to :json

    def index
      conversations = current_api_user.conversations
      render json: conversations
    end

    def show
      conversation = current_api_user.conversations.includes(:messages).find(params[:id])

      render json: {
        id: conversation.id,
        title: conversation.title,
        model_code: conversation.model_code,
        messages: conversation.messages.order(:created_at).map { |m|
          {
            id: m.id,
            role: m.role,
            content: m.content,
            thinking: m.thinking
          }
        }
      }
    end

    def create
      conversation = current_api_user.conversations.create!(title: "New Chat")
      render json: { id: conversation.id }
    end
  end
end
