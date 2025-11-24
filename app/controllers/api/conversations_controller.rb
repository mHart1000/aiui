module Api
  class ConversationsController < ApplicationController
    before_action :authenticate_with_jwt!
    respond_to :json

    def create
      conversation = current_user.conversations.create!(title: "New Chat")
      render json: { id: conversation.id }
    end
  end
end
