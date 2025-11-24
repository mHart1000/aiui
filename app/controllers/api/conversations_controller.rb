module Api
  class ConversationsController < ApplicationController
    before_action :authenticate_user!

    def create
      conversation = Conversation.create!(title: "New Chat")
      render json: { id: conversation.id }
    end
  end
end
