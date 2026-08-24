require "test_helper"

class Api::MessagePendingUploadsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    @user = User.create!(email: "pending-messages@example.com", password: "password123")
    @headers = sign_in_as(@user)
    @conversation = @user.conversations.create!(title: Conversation::PLACEHOLDER_TITLE)
  end

  def teardown
    clear_enqueued_jobs
    PendingImageUpload.delete_all
    ActiveStorage::Attachment.delete_all
    ActiveStorage::Blob.delete_all
    Message.delete_all
    Conversation.delete_all
    Skill.delete_all
    User.delete_all
  end

  def pending_for(user = @user, expires_at: 24.hours.from_now, filename: "small.png")
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(File.binread(file_fixture("small.png"))),
      filename: filename,
      content_type: "image/png",
      metadata: { width: 100, height: 80, original_filename: filename },
      identify: false
    )
    user.pending_image_uploads.create!(blob: blob, expires_at: expires_at)
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

  test "atomically claims a pending upload for an image-only message" do
    pending = pending_for(filename: "vacation.png")

    assert_enqueued_with(job: ConversationEntitleJob, args: [ @conversation.id, "Image: vacation" ]) do
      create_message(content: "", signed_ids: [ pending.client_signed_id ])
    end

    assert_response :success
    message = @conversation.messages.find_by!(role: "user")
    assert message.images.attached?
    assert_equal pending.blob_id, message.images_attachments.first.blob_id
    assert_not PendingImageUpload.exists?(pending.id)
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
    assert_nil @conversation.reload.model_code
  end

  test "blocks a verified unsupported model while retaining the pending upload" do
    pending = pending_for

    assert_no_difference "Message.count" do
      create_message(content: "look", signed_ids: [ pending.client_signed_id ], model: "gpt-4")
    end

    assert_response :unprocessable_content
    assert_equal "image_input_unsupported", response.parsed_body.dig("error", "code")
    assert PendingImageUpload.exists?(pending.id)
    assert_nil @conversation.reload.model_code
  end

  test "streaming blocks unsupported image input and retains the pending upload" do
    pending = pending_for

    post "/api/conversations/#{@conversation.id}/messages/stream",
         params: {
           content: "look",
           image_signed_ids: [ pending.client_signed_id ],
           model_code: "gpt-4"
         },
         headers: @headers,
         as: :json

    assert_response :unprocessable_content
    assert_equal "image_input_unsupported", response.parsed_body.dig("error", "code")
    assert PendingImageUpload.exists?(pending.id)
    assert_empty @conversation.messages
  end

  test "accepts an unknown local capability" do
    pending = pending_for

    AiModels.stub(:image_input, "unknown") do
      create_message(content: "look", signed_ids: [ pending.client_signed_id ], model: "local-llama")
    end

    assert_response :success
    assert @conversation.messages.find_by!(role: "user").images.attached?
  end

  test "rejects a duplicate token without consuming it" do
    pending = pending_for
    token = pending.client_signed_id

    create_message(content: "look", signed_ids: [ token, token ])

    assert_response :unprocessable_content
    assert_equal "duplicate_images", response.parsed_body.dig("error", "code")
    assert PendingImageUpload.exists?(pending.id)
  end

  test "hides a foreign pending token and leaves the owned token untouched" do
    owned = pending_for
    other = User.create!(email: "pending-foreign@example.com", password: "password123")
    foreign = pending_for(other)

    create_message(content: "look", signed_ids: [ owned.client_signed_id, foreign.client_signed_id ])

    assert_response :not_found
    assert_equal "attachment_not_found", response.parsed_body.dig("error", "code")
    assert PendingImageUpload.exists?(owned.id)
    assert PendingImageUpload.exists?(foreign.id)
    assert_empty @conversation.messages
  end

  test "a claimed token cannot be reused" do
    pending = pending_for
    token = pending.client_signed_id
    create_message(content: "first", signed_ids: [ token ])
    assert_response :success

    create_message(content: "second", signed_ids: [ token ])

    assert_response :not_found
    assert_equal "attachment_not_found", response.parsed_body.dig("error", "code")
    assert_equal 1, @conversation.messages.where(role: "user").count
  end

  test "rejects an expired pending row without attaching it" do
    pending = pending_for(expires_at: 1.minute.ago)

    create_message(content: "look", signed_ids: [ pending.client_signed_id ])

    assert_response :not_found
    assert_includes %w[attachment_not_found attachment_expired], response.parsed_body.dig("error", "code")
    assert PendingImageUpload.exists?(pending.id)
  end
end
