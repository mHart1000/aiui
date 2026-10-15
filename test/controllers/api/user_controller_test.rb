require "test_helper"

module Api
  class UserControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "user_#{SecureRandom.hex(4)}@example.com", password: "password123")
      @headers = sign_in_as(@user)
    end

    test "reasoning effort defaults to high and accepts only supported levels" do
      get "/api/user", headers: @headers
      assert_equal "high", JSON.parse(response.body)["reasoning_effort"]
      %w[none low medium high].each do |effort|
        patch "/api/user", params: { user: { reasoning_effort: effort } }, headers: @headers, as: :json
        assert_response :success
        assert_equal effort, @user.reload.reasoning_effort
        assert_equal effort, JSON.parse(response.body)["reasoning_effort"]
      end
      [ nil, "", "ultra" ].each do |effort|
        patch "/api/user", params: { user: { reasoning_effort: effort } }, headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_equal "high", @user.reload.reasoning_effort
      end
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
            params: { user: { web_search_mode: "always", web_search_level: "high", web_search_query_count: 5 } }, headers: @headers, as: :json

      assert_response :success
      assert_equal "always", @user.reload.web_search_mode
      assert_equal "high", @user.reload.web_search_level
      assert_equal 5, @user.web_search_query_count
      assert_equal 5, JSON.parse(response.body)["web_search_query_count"]
    end

    test "query count rejects fractions and values outside the selector range" do
      [ 0, 6, 1.5, "invalid", nil ].each do |value|
        previous = @user.reload.web_search_query_count
        patch "/api/user", params: { user: { web_search_query_count: value } }, headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_equal previous, @user.reload.web_search_query_count
      end
    end

    test "update rejects an unknown web search level" do
      patch "/api/user", params: { user: { web_search_level: "ultra" } }, headers: @headers, as: :json

      assert_response :unprocessable_entity
      assert_equal "low", @user.reload.web_search_level
    end
  end
end
