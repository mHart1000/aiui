require "test_helper"

module Api
  class ConversationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "conversations_#{SecureRandom.hex(4)}@example.com", password: "password123")
      @headers = sign_in_as(@user)
      @conversation = @user.conversations.create!(title: "Debugging Rails")
      @conversation.messages.create!(role: "user", content: "one")
      @answer = @conversation.messages.create!(role: "assistant", content: "two")
      @conversation.messages.create!(role: "user", content: "three")
    end

    test "fork creates a conversation holding the messages up to the given one" do
      assert_difference -> { @user.conversations.count }, 1 do
        post "/api/conversations/#{@conversation.id}/fork",
             params: { message_id: @answer.id }, headers: @headers, as: :json
      end
      assert_response :created

      forked = Conversation.find(JSON.parse(response.body)["id"])
      assert_equal @user.id, forked.user_id
      assert_equal "(fork) Debugging Rails", forked.title
      assert_equal [ "one", "two" ], forked.messages.order(:created_at).map(&:content)
    end

    test "fork rejects another user's conversation" do
      other = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com", password: "password123")
      theirs = other.conversations.create!(title: "Theirs")
      message = theirs.messages.create!(role: "user", content: "hi")

      post "/api/conversations/#{theirs.id}/fork",
           params: { message_id: message.id }, headers: @headers, as: :json

      assert_response :not_found
    end

    test "fork rejects a message from a different conversation" do
      other = @user.conversations.create!(title: "Other")
      stranger = other.messages.create!(role: "user", content: "hi")

      post "/api/conversations/#{@conversation.id}/fork",
           params: { message_id: stranger.id }, headers: @headers, as: :json

      assert_response :not_found
    end
  end
end
