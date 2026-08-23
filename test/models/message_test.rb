require "test_helper"

class MessageTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "test@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "New Chat")
  end

  # multimodal_content
  test "multimodal_content returns the plain string when there are no images" do
    message = @conversation.messages.create!(role: "user", content: "Hello")
    assert_equal "Hello", message.multimodal_content
  end

  test "multimodal_content uses the default empty image_data array" do
    message = @conversation.messages.create!(role: "user", content: "Hello")
    assert_equal [], message.image_data
    assert_equal "Hello", message.multimodal_content
  end

  test "multimodal_content returns the array form when images are present" do
    image = "data:image/jpeg;base64,abc123"
    message = @conversation.messages.create!(
      role: "user",
      content: "What is this?",
      image_data: [ image ]
    )
    assert_equal(
      [
        { type: "text", text: "What is this?" },
        { type: "image_url", image_url: { url: image } }
      ],
      message.multimodal_content
    )
  end

  test "multimodal_content emits one image_url part per image, in order" do
    first = "data:image/png;base64,first"
    second = "data:image/jpeg;base64,second"
    message = @conversation.messages.create!(
      role: "user",
      content: "Two pictures",
      image_data: [ first, second ]
    )
    parts = message.multimodal_content
    assert_equal "text", parts[0][:type]
    assert_equal "Two pictures", parts[0][:text]
    assert_equal "image_url", parts[1][:type]
    assert_equal first, parts[1][:image_url][:url]
    assert_equal "image_url", parts[2][:type]
    assert_equal second, parts[2][:image_url][:url]
    assert_equal 3, parts.length
  end
end
