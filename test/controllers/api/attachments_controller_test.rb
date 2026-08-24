require "test_helper"

class Api::AttachmentsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(email: "attachments@example.com", password: "password123")
    @headers = sign_in_as(@user)
  end

  def teardown
    PendingImageUpload.delete_all
    ActiveStorage::Attachment.delete_all
    ActiveStorage::Blob.delete_all
    Message.delete_all
    Conversation.delete_all
    Skill.delete_all
    User.delete_all
  end

  def upload(filename, content_type, headers: @headers)
    post "/api/attachments",
         params: { file: fixture_file_upload(filename, content_type) },
         headers: headers
  end

  test "normalizes an image below the cap without changing dimensions" do
    upload("small.png", "image/png")

    assert_response :created
    body = response.parsed_body
    assert_equal 100, body["width"]
    assert_equal 80, body["height"]
    assert_nil body["url"]

    pending = PendingImageUpload.find_signed!(
      body["signed_id"], purpose: PendingImageUpload::SIGNED_ID_PURPOSE
    )
    assert_equal @user, pending.user
    assert_equal body["id"], pending.id
    assert_equal "image/png", pending.blob.content_type
    assert_equal "small.png", pending.blob.filename.to_s
    assert_not_equal File.binread(file_fixture("small.png")), pending.blob.download
  end

  test "downscales an oversized image to the cap and no further" do
    upload("large.jpg", "image/jpeg")

    assert_response :created
    body = response.parsed_body
    pixels = body["width"] * body["height"]

    assert pixels <= @user.image_max_pixels, "expected #{pixels} to fit the cap"
    assert pixels > @user.image_max_pixels * 0.95, "resized well below the cap"
    assert_in_delta 3000.0 / 2400.0, body["width"].to_f / body["height"], 0.01
  end

  test "honours the minimum per-user cap" do
    @user.update!(image_max_pixels: User::MIN_IMAGE_MAX_PIXELS)
    upload("large.jpg", "image/jpeg")

    assert_response :created
    body = response.parsed_body
    assert (body["width"] * body["height"]) <= User::MIN_IMAGE_MAX_PIXELS
  end

  test "uses byte-detected MIME rather than the declared MIME" do
    upload("small.png", "text/plain")

    assert_response :created
    assert_equal "image/png", response.parsed_body["content_type"]
  end

  test "returns a structured error for unsupported bytes" do
    upload("sample.txt", "image/png")

    assert_response :unprocessable_content
    assert_equal "unsupported_image_type", response.parsed_body.dig("error", "code")
  end

  test "returns a structured error when the file is missing" do
    post "/api/attachments", params: {}, headers: @headers

    assert_response :unprocessable_content
    assert_equal "missing_file", response.parsed_body.dig("error", "code")
  end

  test "purges the blob record when storage upload fails" do
    failing_upload = ->(*_args, **_kwargs) { raise IOError, "disk unavailable" }

    ActiveStorage::Blob.service.stub(:upload, failing_upload) do
      assert_no_difference [ "ActiveStorage::Blob.count", "PendingImageUpload.count" ] do
        upload("small.png", "image/png")
      end
    end

    assert_response :internal_server_error
    assert_equal "upload_failed", response.parsed_body.dig("error", "code")
  end

  test "deletes only an owned pending upload" do
    upload("small.png", "image/png")
    pending = PendingImageUpload.find(response.parsed_body["id"])

    delete "/api/attachments/#{pending.id}", headers: @headers

    assert_response :no_content
    assert_not PendingImageUpload.exists?(pending.id)
  end

  test "hides another user's pending upload on delete" do
    upload("small.png", "image/png")
    pending_id = response.parsed_body["id"]
    other = User.create!(email: "attachment-other@example.com", password: "password123")

    delete "/api/attachments/#{pending_id}", headers: sign_in_as(other)

    assert_response :not_found
    assert_equal "attachment_not_found", response.parsed_body.dig("error", "code")
    assert PendingImageUpload.exists?(pending_id)
  end

  test "rejects deleting an already attached pending blob" do
    upload("small.png", "image/png")
    pending = PendingImageUpload.find(response.parsed_body["id"])
    conversation = @user.conversations.create!(title: "Used")
    conversation.messages.create!(role: "user", content: "used", images: [ pending.blob ])

    delete "/api/attachments/#{pending.id}", headers: @headers

    assert_response :conflict
    assert_equal "attachment_already_used", response.parsed_body.dig("error", "code")
  end

  test "requires authentication" do
    post "/api/attachments", params: { file: fixture_file_upload("small.png", "image/png") }

    assert_response :unauthorized
  end
end
