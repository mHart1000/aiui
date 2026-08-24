require "test_helper"

class Api::MessageImagesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(email: "private-images@example.com", password: "password123")
    @headers = sign_in_as(@user)
    @conversation = @user.conversations.create!(title: "Private")
    @message = @conversation.messages.create!(role: "user", content: "image")
    @message.images.attach(
      io: File.open(file_fixture("small.png")),
      filename: "small.png",
      content_type: "image/png",
      identify: false,
      metadata: { width: 100, height: 80 }
    )
    @attachment = @message.images_attachments.first
    @path = "/api/conversations/#{@conversation.id}/messages/#{@message.id}/images/#{@attachment.id}"
  end

  test "owner receives inline bytes with private security headers" do
    get @path, headers: @headers

    assert_response :success
    assert_equal @attachment.download, response.body
    assert_equal "image/png", response.media_type
    assert_match(/inline/, response.headers["Content-Disposition"])
    assert_match(/small\.png/, response.headers["Content-Disposition"])
    assert_includes response.headers["Cache-Control"], "private"
    assert_includes response.headers["Cache-Control"], "max-age=3600"
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
  end

  test "requires authentication" do
    get @path
    assert_response :unauthorized
  end

  test "hides another user's image" do
    other = User.create!(email: "private-images-other@example.com", password: "password123")
    get @path, headers: sign_in_as(other)
    assert_response :not_found
    assert_equal "image_not_found", response.parsed_body.dig("error", "code")
  end

  test "rejects an attachment from a different message" do
    other_message = @conversation.messages.create!(role: "user", content: "other")
    path = "/api/conversations/#{@conversation.id}/messages/#{other_message.id}/images/#{@attachment.id}"

    get path, headers: @headers
    assert_response :not_found
    assert_equal "image_not_found", response.parsed_body.dig("error", "code")
  end
end
