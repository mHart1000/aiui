require "test_helper"
require "stringio"

module Api
  class MessageImagesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "images_#{SecureRandom.hex(4)}@example.com", password: "password123")
      @headers = sign_in_as(@user)
      @conversation = @user.conversations.create!(title: "Images")
      @message = @conversation.messages.create!(role: "user", content: "look")
      @message.images.attach(
        io: StringIO.new("private image"),
        filename: "private.png",
        content_type: "image/png",
        identify: false
      )
      @attachment = @message.images_attachments.first
    end

    test "owner can retrieve a private image" do
      get image_path, headers: @headers

      assert_response :success
      assert_equal "private image", response.body
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      assert_equal "image/png", response.media_type
    end

    test "another user receives not found" do
      other = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com", password: "password123")
      other_headers = sign_in_as(other)

      get image_path, headers: other_headers
      assert_response :not_found
    end

    private

    def image_path
      "/api/conversations/#{@conversation.id}/messages/#{@message.id}/images/#{@attachment.id}"
    end
  end
end
