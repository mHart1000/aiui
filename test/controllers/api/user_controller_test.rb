require "test_helper"

module Api
  class UserControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "user_#{SecureRandom.hex(4)}@example.com", password: "password123")
      @headers = sign_in_as(@user)
    end

    test "show serializes the web search mode and level defaults" do
      get "/api/user", headers: @headers

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "off", body["web_search_mode"]
      assert_equal "low", body["web_search_level"]
    end

    test "update persists the web search mode and level defaults" do
      patch "/api/user",
            params: { user: { web_search_mode: "always", web_search_level: "high" } }, headers: @headers, as: :json

      assert_response :success
      assert_equal "always", @user.reload.web_search_mode
      assert_equal "high", @user.reload.web_search_level
    end

    test "update rejects an unknown web search level" do
      patch "/api/user", params: { user: { web_search_level: "ultra" } }, headers: @headers, as: :json

      assert_response :unprocessable_entity
      assert_equal "low", @user.reload.web_search_level
    end
  end
end