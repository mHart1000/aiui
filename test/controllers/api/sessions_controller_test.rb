require "test_helper"

class Api::SessionsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(email: "test@example.com", password: "password123")
  end

  test "login returns user and token with valid credentials" do
    post "/api/login", params: { user: { email: "test@example.com", password: "password123" } }, as: :json
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "test@example.com", body["user"]["email"]
    assert body["token"].present?
  end

  test "login returns unauthorized with wrong password" do
    post "/api/login", params: { user: { email: "test@example.com", password: "wrongpassword" } }, as: :json
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "Invalid email or password", body["error"]
  end

  test "login returns unauthorized with nonexistent email" do
    post "/api/login", params: { user: { email: "nobody@example.com", password: "password123" } }, as: :json
    assert_response :unauthorized
  end

  test "logout returns success" do
    delete "/api/logout", as: :json
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Logged out", body["message"]
  end
end
