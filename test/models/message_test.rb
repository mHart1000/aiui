require "test_helper"

class MessageTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "message-images@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Images")
  end

  def teardown
    ActiveStorage::Attachment.delete_all
    ActiveStorage::Blob.delete_all
    Message.delete_all
    Conversation.delete_all
    Skill.delete_all
    User.delete_all
  end

  def message_with_image(content: "what is this", filename: "small.png", type: "image/png")
    message = @conversation.messages.create!(role: "user", content: content)
    message.images.attach(
      io: File.open(Rails.root.join("test/fixtures/files", filename)),
      filename: filename,
      content_type: type
    )
    message
  end

  test "to_ai_payload keeps a plain string when there are no images" do
    message = @conversation.messages.create!(role: "user", content: "hello")

    assert_equal({ role: "user", content: "hello" }, message.to_ai_payload(multimodal: true))
  end

  test "to_ai_payload builds a content array for a vision model" do
    payload = message_with_image.to_ai_payload(multimodal: true)

    assert_equal "user", payload[:role]
    assert_equal({ type: "text", text: "what is this" }, payload[:content].first)

    image_part = payload[:content].last
    assert_equal "image_url", image_part[:type]
    assert image_part[:image_url][:url].start_with?("data:image/png;base64,")
  end

  test "to_ai_payload omits the text part when the turn is images only" do
    parts = message_with_image(content: "").to_ai_payload(multimodal: true)[:content]

    assert_equal 1, parts.size
    assert_equal "image_url", parts.first[:type]
  end

  test "to_ai_payload degrades to a filename marker for a text-only model" do
    payload = message_with_image(content: "read this").to_ai_payload(multimodal: false)

    assert_equal "read this\n\n[Image attached: small.png]", payload[:content]
  end

  test "rejects an attachment that is not an image" do
    message = @conversation.messages.new(role: "user", content: "nope")
    message.images.attach(
      io: File.open(Rails.root.join("test/fixtures/files/sample.txt")),
      filename: "sample.txt",
      content_type: "text/plain"
    )

    assert_not message.valid?
    assert_match(/JPEG or PNG/, message.errors[:images].join)
  end

  test "rejects more than MAX_IMAGES attachments" do
    message = @conversation.messages.new(role: "user", content: "too many")
    (Message::MAX_IMAGES + 1).times do
      message.images.attach(
        io: File.open(Rails.root.join("test/fixtures/files/small.png")),
        filename: "small.png",
        content_type: "image/png"
      )
    end

    assert_not message.valid?
    assert_match(/cannot exceed/, message.errors[:images].join)
  end
end
