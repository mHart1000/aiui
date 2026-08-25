require "test_helper"

class UserTest < ActiveSupport::TestCase
  def setup
    @user = User.new(email: "test@example.com", password: "password123")
  end

  # validations
  test "valid user can be saved" do
    assert @user.save
  end

  test "email must be present" do
    @user.email = nil
    refute @user.valid?
    assert_includes @user.errors[:email], "can't be blank"
  end

  test "email must be unique" do
    @user.save!
    duplicate = User.new(email: "test@example.com", password: "password123")
    refute duplicate.valid?
    assert_includes duplicate.errors[:email], "has already been taken"
  end

  test "password must be at least 6 characters" do
    @user.password = "abc"
    refute @user.valid?
    assert_includes @user.errors[:password], "is too short (minimum is 6 characters)"
  end

  # defaults
  test "use_scaffolding defaults to true" do
    @user.save!
    assert @user.reload.use_scaffolding
  end

  test "tts_enabled defaults to false" do
    @user.save!
    refute @user.reload.tts_enabled
  end

  test "tts_speed defaults to 1.0" do
    @user.save!
    assert_equal 1.0, @user.reload.tts_speed
  end

  # associations
  test "destroying a user destroys their conversations" do
    @user.save!
    @user.conversations.create!(title: "Test convo")
    assert_difference "Conversation.count", -1 do
      @user.destroy
    end
  end
end
