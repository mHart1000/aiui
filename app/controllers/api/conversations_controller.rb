module Api
  class ConversationsController < ApplicationController
    before_action :authenticate_api_user!
    respond_to :json

    def create
      conversation = current_api_user.conversations.create!(title: "New Chat")
      render json: { id: conversation.id }
    end
  end
end
