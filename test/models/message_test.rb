require "test_helper"
require "base64"
require "stringio"

class MessageTest < ActiveSupport::TestCase
  test "image messages become ordered OpenAI-compatible content blocks" do
    user = User.create!(email: "message_#{SecureRandom.hex(4)}@example.com", password: "password123")
    conversation = user.conversations.create!(title: "Vision")
    message = conversation.messages.create!(role: "user", content: "Describe this")
    message.images.attach(
      io: StringIO.new("png bytes"),
      filename: "sample.png",
      content_type: "image/png",
      metadata: { width: 10, height: 20 },
      identify: false
    )

    content = message.content_for_ai
    assert_equal({ type: "text", text: "Describe this" }, content.first)
    assert_equal "image_url", content.second[:type]
    assert_equal "data:image/png;base64,#{Base64.strict_encode64('png bytes')}", content.second.dig(:image_url, :url)
  end

  test "image-only messages do not invent a text part" do
    user = User.create!(email: "image_only_#{SecureRandom.hex(4)}@example.com", password: "password123")
    conversation = user.conversations.create!(title: "Vision")
    message = conversation.messages.create!(role: "user", content: "")
    message.images.attach(
      io: StringIO.new("png bytes"),
      filename: "sample.png",
      content_type: "image/png",
      identify: false
    )

    assert_equal [ "image_url" ], message.content_for_ai.map { |part| part[:type] }
  end
end
