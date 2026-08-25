require "test_helper"

class Api::MessageImageUploadsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

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

  def upload_blob(created_at: Time.current, filename: "small.png")
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(File.binread(file_fixture("small.png"))),
      filename: filename,
      content_type: "image/png",
      metadata: { width: 100, height: 80, original_filename: filename },
      identify: false
    )
    blob.update_column(:created_at, created_at)
    blob
  end

  def create_message(content:, signed_ids: [], model: "openrouter/google/gemma-3-27b-it:free")
    result = {
      reply: "answer", thinking: nil,
      tokens: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
      stats: nil, persona_version: nil, skill_versions: nil
    }
    ChatService.stub(:call, result) do
      post "/api/conversations/#{@conversation.id}/messages",
           params: { content: content, image_signed_ids: signed_ids, model_code: model },
           headers: @headers,
           as: :json
    end
  end

  test "atomically claims a blob for an image-only message" do
    blob = upload_blob(filename: "vacation.png")

    assert_enqueued_with(job: ConversationEntitleJob, args: [ @conversation.id, "Image: vacation" ]) do
      create_message(content: "", signed_ids: [ blob.signed_id ])
    end

    assert_response :success
    message = @conversation.messages.find_by!(role: "user")
    assert_equal blob.id, message.images_attachments.first.blob_id
  end

  test "rejects an empty message before persistence" do
    assert_no_difference "Message.count" do
      create_message(content: "")
    end

    assert_response :unprocessable_content
    assert_equal "message_content_required", response.parsed_body.dig("error", "code")
    assert_nil @conversation.reload.model_code
  end

  test "streaming rejects an empty message before opening SSE" do
    post "/api/conversations/#{@conversation.id}/messages/stream",
         params: { content: "", model_code: "openrouter/google/gemma-3-27b-it:free" },
         headers: @headers,
         as: :json

    assert_response :unprocessable_content
    assert_equal "application/json", response.media_type
    assert_equal "message_content_required", response.parsed_body.dig("error", "code")
    assert_empty @conversation.messages
  end

  test "blocks verified unsupported models without consuming the blob" do
    blob = upload_blob

    assert_no_difference "Message.count" do
      create_message(content: "look", signed_ids: [ blob.signed_id ], model: "gpt-4")
    end

    assert_response :unprocessable_content
    assert_equal "image_input_unsupported", response.parsed_body.dig("error", "code")
    assert_not blob.attachments.exists?
  end

  test "accepts unknown local capability" do
    blob = upload_blob

    AiModels.stub(:image_input, "unknown") do
      create_message(content: "look", signed_ids: [ blob.signed_id ], model: "local-llama")
    end

    assert_response :success
    assert @conversation.messages.find_by!(role: "user").images.attached?
  end

  test "rejects a duplicate token without consuming it" do
    blob = upload_blob

    create_message(content: "look", signed_ids: [ blob.signed_id, blob.signed_id ])

    assert_response :unprocessable_content
    assert_equal "duplicate_images", response.parsed_body.dig("error", "code")
    assert_not blob.attachments.exists?
  end

  test "a claimed token cannot be reused" do
    blob = upload_blob
    create_message(content: "first", signed_ids: [ blob.signed_id ])
    assert_response :success

    create_message(content: "second", signed_ids: [ blob.signed_id ])

    assert_response :conflict
    assert_equal "attachment_already_used", response.parsed_body.dig("error", "code")
    assert_equal 1, @conversation.messages.where(role: "user").count
  end

  test "rejects an expired blob without attaching it" do
    blob = upload_blob(created_at: ImageAttachmentProcessor::UPLOAD_TTL.ago - 1.minute)

    create_message(content: "look", signed_ids: [ blob.signed_id ])

    assert_response :unprocessable_content
    assert_equal "attachment_expired", response.parsed_body.dig("error", "code")
    assert_not blob.attachments.exists?
  end
end
