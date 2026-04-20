module Api
  class ConversationsController < ApplicationController
    before_action :authenticate_api_user!
    respond_to :json

    def index
      conversations = current_api_user.conversations
      render json: conversations.map { |c|
        {
          id: c.id,
          title: c.title,
          model_code: c.model_code,
          rag_enabled: c.rag_enabled
        }
      }
    end

    def show
      conversation = current_api_user.conversations.includes(:messages).find(params[:id])

      render json: {
        id: conversation.id,
        title: conversation.title,
        model_code: conversation.model_code,
        rag_enabled: conversation.rag_enabled,
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

    def update
      conversation = current_api_user.conversations.find(params[:id])
      conversation.update!(conversation_params)
      render json: {
        id: conversation.id,
        title: conversation.title,
        model_code: conversation.model_code,
        rag_enabled: conversation.rag_enabled
      }
    end

    private

    def conversation_params
      params.require(:conversation).permit(:rag_enabled)
    end
  end
end
