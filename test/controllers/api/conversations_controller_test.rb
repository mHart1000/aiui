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

    test "fork copies attached images onto its own blobs" do
      first = @conversation.messages.order(:created_at).first
      first.images.attach(
        io: File.open(Rails.root.join("test/fixtures/files/small.png")),
        filename: "small.png",
        content_type: "image/png",
        identify: false,
        metadata: { width: 100, height: 80, original_filename: "camera.png" }
      )

      post "/api/conversations/#{@conversation.id}/fork",
           params: { message_id: @answer.id }, headers: @headers, as: :json
      assert_response :created

      forked = Conversation.find(JSON.parse(response.body)["id"])
      copied = forked.messages.order(:created_at).first

      assert_equal 1, copied.images.attachments.size
      assert_equal "small.png", copied.images.attachments.first.blob.filename.to_s
      # Separate blobs, so purging one conversation cannot empty the other.
      assert_not_equal first.images.attachments.first.blob_id,
                       copied.images.attachments.first.blob_id
      assert_equal 100, copied.images.attachments.first.blob.metadata["width"]
      assert_equal "camera.png", copied.images.attachments.first.blob.metadata["original_filename"]
    end

    test "show serializes attached images" do
      first = @conversation.messages.order(:created_at).first
      first.images.attach(
        io: File.open(Rails.root.join("test/fixtures/files/small.png")),
        filename: "small.png",
        content_type: "image/png"
      )

      get "/api/conversations/#{@conversation.id}", headers: @headers
      assert_response :success

      images = JSON.parse(response.body)["messages"].first["images"]
      assert_equal 1, images.size
      assert_equal "small.png", images.first["filename"]
      assert_equal "image/png", images.first["content_type"]
      assert_nil images.first["url"]
      assert_equal "/api/conversations/#{@conversation.id}/messages/#{first.id}/images/#{images.first['id']}", images.first["download_url"]
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
