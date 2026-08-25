require "test_helper"

class Api::AttachmentsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(email: "attachments@example.com", password: "password123")
    @headers = sign_in_as(@user)
  end

  def teardown
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

  test "normalizes an image and returns a signed blob capability" do
    upload("small.png", "image/png")

    assert_response :created
    body = response.parsed_body
    assert_equal 100, body["width"]
    assert_equal 80, body["height"]
    assert_match %r{\A/rails/active_storage/blobs/}, body["url"]
    assert_in_delta 24.hours.from_now, Time.iso8601(body["expires_at"]), 5.seconds

    blob = ActiveStorage::Blob.find_signed!(body["signed_id"])
    assert_equal body["id"], blob.id
    assert_equal "image/png", blob.content_type
    assert_equal "small.png", blob.filename.to_s
    assert_not_equal File.binread(file_fixture("small.png")), blob.download
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

  test "returns structured errors for unsupported or missing files" do
    upload("sample.txt", "image/png")
    assert_response :unprocessable_content
    assert_equal "unsupported_image_type", response.parsed_body.dig("error", "code")

    post "/api/attachments", params: {}, headers: @headers
    assert_response :unprocessable_content
    assert_equal "missing_file", response.parsed_body.dig("error", "code")
  end

  test "purges the blob record when storage upload fails" do
    failing_upload = ->(*_args, **_kwargs) { raise IOError, "disk unavailable" }

    ActiveStorage::Blob.service.stub(:upload, failing_upload) do
      assert_no_difference "ActiveStorage::Blob.count" do
        upload("small.png", "image/png")
      end
    end

    assert_response :internal_server_error
    assert_equal "upload_failed", response.parsed_body.dig("error", "code")
  end

  test "deletes an unattached upload using its signed capability" do
    upload("small.png", "image/png")
    body = response.parsed_body

    delete "/api/attachments/#{body['signed_id']}", headers: @headers

    assert_response :no_content
    assert_not ActiveStorage::Blob.exists?(body["id"])
  end

  test "rejects invalid deletion capabilities" do
    delete "/api/attachments/not-a-signed-id", headers: @headers

    assert_response :not_found
    assert_equal "attachment_not_found", response.parsed_body.dig("error", "code")
  end

  test "rejects deleting an already attached blob" do
    upload("small.png", "image/png")
    body = response.parsed_body
    blob = ActiveStorage::Blob.find(body["id"])
    conversation = @user.conversations.create!(title: "Used")
    conversation.messages.create!(role: "user", content: "used", images: [ blob ])

    delete "/api/attachments/#{body['signed_id']}", headers: @headers

    assert_response :conflict
    assert_equal "attachment_already_used", response.parsed_body.dig("error", "code")
    assert ActiveStorage::Blob.exists?(blob.id)
  end

  test "requires authentication" do
    post "/api/attachments", params: { file: fixture_file_upload("small.png", "image/png") }

    assert_response :unauthorized
  end
end
