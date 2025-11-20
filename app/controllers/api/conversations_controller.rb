module Api
  class ConversationsController < ApplicationController
    def create
      conversation = Conversation.create!(title: "New Chat")
      render json: { id: conversation.id }
    end
  end
end
