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
    User.delete_all
  end

  def upload(filename, content_type)
    post "/api/attachments",
         params: { file: fixture_file_upload(filename, content_type) },
         headers: @headers
  end

  # Rule 1: anything at or below the cap must survive byte-for-byte, or screenshot
  # text stops being legible. See docs/image-attachments-spec.md §2.2.
  test "stores an image below the cap untouched" do
    upload("small.png", "image/png")

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal 100, body["width"]
    assert_equal 80, body["height"]

    blob = ActiveStorage::Blob.find_signed!(body["signed_id"])
    original = File.binread(Rails.root.join("test/fixtures/files/small.png"))
    assert_equal original, blob.download
  end

  # Rule 2: resize *to* the cap, not below it.
  test "downscales an oversized image to the cap and no further" do
    upload("large.jpg", "image/jpeg")

    assert_response :created
    body = JSON.parse(response.body)
    pixels = body["width"] * body["height"]

    assert pixels <= @user.image_max_pixels, "expected #{pixels} to fit the cap"
    assert pixels > @user.image_max_pixels * 0.95, "resized well below the cap, losing detail for nothing"
    assert_in_delta 3000.0 / 2400.0, body["width"].to_f / body["height"], 0.01, "aspect ratio drifted"
  end

  test "honours a lowered per-user cap" do
    @user.update!(image_max_pixels: 200_000)
    upload("large.jpg", "image/jpeg")

    assert_response :created
    body = JSON.parse(response.body)
    assert (body["width"] * body["height"]) <= 200_000
  end

  test "rejects a file that is not an image" do
    upload("sample.txt", "text/plain")

    assert_response :unprocessable_entity
    assert_match(/unsupported image format/, JSON.parse(response.body)["error"])
  end

  test "rejects a request with no file" do
    post "/api/attachments", params: {}, headers: @headers

    assert_response :unprocessable_entity
  end

  test "requires authentication" do
    post "/api/attachments", params: { file: fixture_file_upload("small.png", "image/png") }

    assert_response :unauthorized
  end
end
