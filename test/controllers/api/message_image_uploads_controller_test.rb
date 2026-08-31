require "test_helper"

class Api::MessageImageUploadsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  MODEL = "local-llama"

  def setup
    @user = User.create!(email: "image-messages@example.com", password: "password123")
    @headers = sign_in_as(@user)
    @conversation = @user.conversations.create!(title: Conversation::PLACEHOLDER_TITLE)
  end

  def teardown
    clear_enqueued_jobs
    ActiveStorage::Attachment.delete_all
    ActiveStorage::Blob.delete_all
    Message.delete_all
    Conversation.delete_all
    Skill.delete_all
    User.delete_all
  end

  def image(filename = "small.png", content_type = "image/png")
    fixture_file_upload(filename, content_type)
  end

  def stream_message(content:, images: [], model: MODEL, &capture)
    service = lambda do |**kwargs, &block|
      capture&.call(kwargs)
      block.call("answer", :response)
      {
        tokens: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
        stats: nil, persona_version: nil, skill_versions: nil
      }
    end
    AiModels.stub(:local_image_input, true) do
      ChatService.stub(:call, service) do
        post "/api/conversations/#{@conversation.id}/messages/stream",
             params: { content: content, images: images, model_code: model },
             headers: @headers
      end
    end
  end

  test "accepts an image-only multipart message without generating a filename title" do
    assert_no_enqueued_jobs only: ConversationEntitleJob do
      stream_message(content: "", images: [ image ])
    end

    assert_response :success
    message = @conversation.messages.find_by!(role: "user")
    assert message.images.attached?
    assert_equal "small.png", message.images.first.filename.to_s
    assert_equal Conversation::PLACEHOLDER_TITLE, @conversation.reload.title
  end

  test "accepts multiple images" do
    stream_message(content: "compare", images: [ image, image ])

    assert_response :success
    assert_equal 2, @conversation.messages.find_by!(role: "user").images.blobs.size
  end

  test "rejects the entire request when one selected image is invalid" do
    assert_no_difference [ "Message.count", "ActiveStorage::Blob.count" ] do
      stream_message(content: "mixed", images: [ image, image("sample.txt", "image/png") ])
    end

    assert_response :internal_server_error
    assert_nil @conversation.reload.model_code
  end

  test "direct non-local requests store images and send filename markers" do
    captured = nil
    stream_message(
      content: "look",
      images: [ image ],
      model: "openrouter/google/gemma-4-31b-it:free"
    ) { |kwargs| captured = kwargs[:messages] }

    assert_response :success
    assert_match(/"type":"done"/, response.body)
    assert @conversation.messages.find_by!(role: "user").images.attached?
    assert_equal "look\n\n[Image attached: small.png]", captured.last[:content]
  end
end
