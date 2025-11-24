module Api
  class ConversationsController < ApplicationController
    before_action :authenticate_user!

    def create
      conversation = current_user.conversations.create!(title: "New Chat")
      render json: { id: conversation.id }
    end
  end
end
