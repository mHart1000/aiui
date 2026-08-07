require "test_helper"

class SkillTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "skill_#{SecureRandom.hex(4)}@example.com", password: "password123")
  end

  test "new users are seeded with the default skills" do
    assert_equal DEFAULT_SKILLS.length, @user.skills.count
    assert_equal DEFAULT_SKILLS.map { |s| s["name"] }.sort, @user.skills.pluck(:name).sort
  end

  test "seeded skills start disabled so nothing injects until the user opts in" do
    assert_empty @user.skills.where(enabled_by_default: true)
  end

  test "version is an 8-char sha1 of the body" do
    skill = @user.skills.create!(name: "V", body: "BODY")
    assert_equal Digest::SHA1.hexdigest("BODY")[0, 8], skill.version
  end

  test "version changes when the body changes" do
    skill = @user.skills.create!(name: "V", body: "BODY")
    before = skill.version
    skill.update!(body: "DIFFERENT")
    assert_not_equal before, skill.version
  end

  test "name and body are required" do
    assert_not @user.skills.new(body: "B").valid?
    assert_not @user.skills.new(name: "N").valid?
  end

  test "name is unique per user but reusable across users" do
    @user.skills.create!(name: "Shared", body: "B")
    assert_not @user.skills.new(name: "Shared", body: "B").valid?

    other = User.create!(email: "other_#{SecureRandom.hex(4)}@example.com", password: "password123")
    assert other.skills.new(name: "Shared", body: "B").valid?
  end

  test "destroying a user destroys their skills" do
    id = @user.skills.first.id
    @user.destroy!
    assert_nil Skill.find_by(id: id)
  end
end
