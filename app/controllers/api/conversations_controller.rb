module Api
  class ConversationsController < ApplicationController
    before_action :authenticate_user!
    before_action :ensure_json_request
    respond_to :json

    def create
      conversation = current_user.conversations.create!(title: "New Chat")
      render json: { id: conversation.id }
    end

    private

    def ensure_json_request
      request.format = :json
    end
  end
end
