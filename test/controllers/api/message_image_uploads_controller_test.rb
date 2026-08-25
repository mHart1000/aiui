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

  def create_message(content:, images: [], model: MODEL, llama_vision: "true")
    result = {
      reply: "answer", thinking: nil,
      tokens: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
      stats: nil, persona_version: nil, skill_versions: nil
    }
    with_env("LLAMA_VISION" => llama_vision) do
      ChatService.stub(:call, result) do
        post "/api/conversations/#{@conversation.id}/messages",
             params: { content: content, images: images, model_code: model },
             headers: @headers
      end
    end
  end

  test "accepts an image-only multipart message without generating a filename title" do
    assert_no_enqueued_jobs only: ConversationEntitleJob do
      create_message(content: "", images: [ image ])
    end

    assert_response :success
    message = @conversation.messages.find_by!(role: "user")
    assert message.images.attached?
    assert_equal "small.png", message.images.first.filename.to_s
    assert_equal Conversation::PLACEHOLDER_TITLE, @conversation.reload.title
  end

  test "accepts multiple images and stores normalized metadata" do
    create_message(content: "compare", images: [ image, image ])

    assert_response :success
    blobs = @conversation.messages.find_by!(role: "user").images.blobs
    assert_equal 2, blobs.size
    assert_equal [ [ 100, 80 ], [ 100, 80 ] ], blobs.map { |blob| blob.metadata.values_at("width", "height") }
  end

  test "rejects an empty message before persistence" do
    assert_no_difference "Message.count" do
      create_message(content: "")
    end

    assert_response :unprocessable_content
    assert_equal "message_content_required", response.parsed_body.dig("error", "code")
    assert_nil @conversation.reload.model_code
  end

  test "rejects too many images before processing any of them" do
    assert_no_difference [ "Message.count", "ActiveStorage::Blob.count" ] do
      create_message(content: "many", images: Array.new(5) { image })
    end

    assert_response :unprocessable_content
    assert_equal "too_many_images", response.parsed_body.dig("error", "code")
  end

  test "rejects the entire request when one selected image is invalid" do
    assert_no_difference [ "Message.count", "ActiveStorage::Blob.count" ] do
      create_message(content: "mixed", images: [ image, image("sample.txt", "image/png") ])
    end

    assert_response :unprocessable_content
    assert_equal "unsupported_image_type", response.parsed_body.dig("error", "code")
    assert_nil @conversation.reload.model_code
  end

  test "blocks non-local models before processing images" do
    assert_no_difference [ "Message.count", "ActiveStorage::Blob.count" ] do
      create_message(content: "look", images: [ image ], model: "openrouter/google/gemma-4-31b-it:free")
    end

    assert_response :unprocessable_content
    assert_equal "image_input_unsupported", response.parsed_body.dig("error", "code")
    assert_nil @conversation.reload.model_code
  end

  test "accepts unavailable local capability" do
    LlamaCapabilities.stub(:image_input, nil) do
      create_message(content: "look", images: [ image ], llama_vision: nil)
    end

    assert_response :success
    assert @conversation.messages.find_by!(role: "user").images.attached?
  end

  test "cleans up the message and blobs when storage upload fails" do
    failing_upload = ->(*_args, **_kwargs) { raise IOError, "disk unavailable" }

    ActiveStorage::Blob.service.stub(:upload, failing_upload) do
      assert_no_difference [ "Message.count", "ActiveStorage::Blob.count" ] do
        create_message(content: "look", images: [ image ])
      end
    end

    assert_response :internal_server_error
    assert_equal "upload_failed", response.parsed_body.dig("error", "code")
  end

  test "streaming accepts multipart images" do
    service = lambda do |**_kwargs, &block|
      block.call("answer", :response)
      { persona_version: nil }
    end

    with_env("LLAMA_VISION" => "true") do
      ChatService.stub(:call, service) do
        post "/api/conversations/#{@conversation.id}/messages/stream",
             params: { content: "look", images: [ image ], model_code: MODEL },
             headers: @headers
      end
    end

    assert_response :success
    assert_match(/"type":"done"/, response.body)
    assert @conversation.messages.find_by!(role: "user").images.attached?
  end
end
