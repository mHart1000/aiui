require "test_helper"

module Api
  class SkillsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "skills_#{SecureRandom.hex(4)}@example.com", password: "password123")
      @headers = sign_in_as(@user)
    end

    test "index returns only the current user's skills" do
      other = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com", password: "password123")
      other.skills.create!(name: "Theirs", body: "B")

      get "/api/skills", headers: @headers
      assert_response :success
      names = JSON.parse(response.body).map { |s| s["name"] }
      assert_not_includes names, "Theirs"
      assert_equal @user.skills.count, names.length
    end

    test "create stores a skill owned by the current user" do
      post "/api/skills", params: { skill: { name: "New", description: "D", body: "B" } }, headers: @headers, as: :json
      assert_response :created

      skill = Skill.find(JSON.parse(response.body)["id"])
      assert_equal @user.id, skill.user_id
      assert_not skill.enabled_by_default
    end

    test "create rejects a duplicate name for the same user" do
      @user.skills.create!(name: "Dup", body: "B")

      post "/api/skills", params: { skill: { name: "Dup", body: "B" } }, headers: @headers, as: :json
      assert_response :unprocessable_entity
    end

    test "update toggles enabled_by_default" do
      skill = @user.skills.create!(name: "Toggle", body: "B")

      patch "/api/skills/#{skill.id}", params: { skill: { enabled_by_default: true } }, headers: @headers, as: :json
      assert_response :success
      assert skill.reload.enabled_by_default
    end

    test "destroy removes the skill" do
      skill = @user.skills.create!(name: "Gone", body: "B")

      delete "/api/skills/#{skill.id}", headers: @headers
      assert_response :no_content
      assert_nil Skill.find_by(id: skill.id)
    end

    test "another user's skill is not reachable" do
      other = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com", password: "password123")
      skill = other.skills.create!(name: "Theirs", body: "B")

      patch "/api/skills/#{skill.id}", params: { skill: { name: "Hijacked" } }, headers: @headers, as: :json
      assert_response :not_found
      assert_equal "Theirs", skill.reload.name
    end
  end
end
