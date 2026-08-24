require "test_helper"

class Api::UserImageSettingsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(email: "image-settings@example.com", password: "password123")
    @headers = sign_in_as(@user)
  end

  test "shows the default image pixel budget" do
    get "/api/user", headers: @headers

    assert_response :success
    assert_equal User::DEFAULT_IMAGE_MAX_PIXELS, response.parsed_body["image_max_pixels"]
  end

  test "persists both valid pixel budget boundaries" do
    [ User::MIN_IMAGE_MAX_PIXELS, User::MAX_IMAGE_MAX_PIXELS ].each do |value|
      patch "/api/user", params: { user: { image_max_pixels: value } }, headers: @headers, as: :json
      assert_response :success
      assert_equal value, response.parsed_body["image_max_pixels"]
      assert_equal value, @user.reload.image_max_pixels
    end
  end

  test "rejects an invalid budget with a structured error and preserves the old value" do
    previous = @user.image_max_pixels

    patch "/api/user",
          params: { user: { image_max_pixels: User::MIN_IMAGE_MAX_PIXELS - 1 } },
          headers: @headers,
          as: :json

    assert_response :unprocessable_entity
    assert_equal "invalid_pixel_budget", response.parsed_body.dig("error", "code")
    assert_equal previous, @user.reload.image_max_pixels
  end
end
