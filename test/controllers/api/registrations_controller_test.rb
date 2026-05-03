require "test_helper"

class Api::RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "signup creates a user and returns a token" do
    assert_difference "User.count", 1 do
      post "/api/signup", params: { user: { email: "new@example.com", password: "password123", password_confirmation: "password123" } }, as: :json
    end
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "new@example.com", body["user"]["email"]
    assert body["token"].present?
  end

  test "signup fails with missing email" do
    assert_no_difference "User.count" do
      post "/api/signup", params: { user: { email: "", password: "password123", password_confirmation: "password123" } }, as: :json
    end
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_includes body["errors"], "Email can't be blank"
  end

  test "signup fails with short password" do
    assert_no_difference "User.count" do
      post "/api/signup", params: { user: { email: "new@example.com", password: "abc", password_confirmation: "abc" } }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "signup fails with duplicate email" do
    User.create!(email: "taken@example.com", password: "password123")
    assert_no_difference "User.count" do
      post "/api/signup", params: { user: { email: "taken@example.com", password: "password123", password_confirmation: "password123" } }, as: :json
    end
    assert_response :unprocessable_entity
  end
end
