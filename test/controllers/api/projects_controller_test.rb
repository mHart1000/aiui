require "test_helper"

class Api::ProjectsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "projects_#{SecureRandom.hex(4)}@example.com", password: "password123")
    @headers = sign_in_as(@user)
    @project = @user.projects.create!(name: "AIUI", description: "Local chat application")
  end

  test "create edit and list projects with description limits" do
    skill = @user.skills.create!(name: "Project skill", body: "Shared instructions")
    post "/api/projects", params: { project: { name: " New project ", description: "Shared context", skill_ids: [ skill.id ] } }, headers: @headers, as: :json
    assert_response :created
    created = response.parsed_body
    assert_equal "New project", created["name"]
    assert_equal [ skill.id ], created["skill_ids"]
    assert_equal @user.id, Project.find(created["id"]).user_id

    patch "/api/projects/#{created['id']}", params: { project: { description: "Updated context", skill_ids: [] } }, headers: @headers, as: :json
    assert_response :success
    assert_equal "Updated context", response.parsed_body["description"]
    assert_empty Project.find(created["id"]).skill_ids

    get "/api/projects", headers: @headers
    assert_response :success
    assert_equal Project::MAX_DESCRIPTION_LENGTH, response.parsed_body.dig("limits", "description")
    assert_equal 2, response.parsed_body["projects"].length
    assert_empty response.parsed_body["projects"].find { |p| p["id"] == created["id"] }["skill_ids"]
  end

  test "description can be cleared" do
    patch "/api/projects/#{@project.id}", params: { project: { description: nil } }, headers: @headers, as: :json
    assert_response :success
    assert_equal "", @project.reload.description
  end

  test "reject blank names and overlong descriptions without changing the project" do
    [ { name: " " }, { name: "x" * (Project::MAX_NAME_LENGTH + 1) },
      { description: "x" * (Project::MAX_DESCRIPTION_LENGTH + 1) } ].each do |attrs|
      patch "/api/projects/#{@project.id}", params: { project: attrs }, headers: @headers, as: :json
      assert_response :unprocessable_entity
      assert response.parsed_body["errors"].present?
      assert_equal "Local chat application", @project.reload.description
    end
  end

  test "deletion unfiles conversations and keeps their messages" do
    conversation = @user.conversations.create!(project: @project)
    message = conversation.messages.create!(role: "user", content: "Keep me")
    delete "/api/projects/#{@project.id}", headers: @headers
    assert_response :no_content
    assert_nil conversation.reload.project_id
    assert_equal "Keep me", message.reload.content
  end
end
