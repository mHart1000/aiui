require "test_helper"

class ConversationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def setup
    @user = User.create!(email: "test@example.com", password: "password123")
    @conversation = Conversation.new(user: @user, title: "New Chat")
  end

  # placeholder_title?
  test "placeholder_title? returns true when title is 'New Chat'" do
    assert @conversation.placeholder_title?
  end

  test "placeholder_title? returns false when title is something else" do
    @conversation.title = "Debugging my Rails app"
    refute @conversation.placeholder_title?
  end

  # entitle_async
  test "entitle_async enqueues job when title is blank" do
    @conversation.title = nil
    @conversation.save!
    assert_enqueued_with(job: ConversationEntitleJob) do
      @conversation.entitle_async("hello")
    end
  end

  test "entitle_async enqueues job when title is the placeholder" do
    @conversation.save!
    assert_enqueued_with(job: ConversationEntitleJob) do
      @conversation.entitle_async("hello")
    end
  end

  test "entitle_async does not enqueue job when title is already set" do
    @conversation.title = "Debugging my Rails app"
    @conversation.save!
    assert_no_enqueued_jobs do
      @conversation.entitle_async("hello")
    end
  end

  # apply_model_code
  test "apply_model_code updates and returns a valid model code" do
    @conversation.model_code = "claude-sonnet-4-5"
    @conversation.save!
    result = @conversation.apply_model_code("claude-haiku-3-5")
    assert_equal "claude-haiku-3-5", result
    assert_equal "claude-haiku-3-5", @conversation.reload.model_code
  end

  test "apply_model_code falls back to existing model_code when given an invalid code" do
    @conversation.model_code = "claude-sonnet-4-5"
    @conversation.save!
    result = @conversation.apply_model_code("not-a-real-model")
    assert_equal "claude-sonnet-4-5", result
    assert_equal "claude-sonnet-4-5", @conversation.reload.model_code
  end

  test "apply_model_code does not update when the requested code is already set" do
    @conversation.model_code = "claude-sonnet-4-5"
    @conversation.save!
    original_updated_at = @conversation.updated_at
    @conversation.apply_model_code("claude-sonnet-4-5")
    assert_equal original_updated_at, @conversation.reload.updated_at
  end

  # messages_for_ai
  test "messages_for_ai returns an empty array when there are no messages" do
    @conversation.save!
    assert_empty @conversation.messages_for_ai
  end

  test "messages_for_ai returns messages as role/content hashes" do
    @conversation.save!
    @conversation.messages.create!(role: "user", content: "Hello")
    result = @conversation.messages_for_ai
    assert_equal [{ role: "user", content: "Hello" }], result
  end

  test "messages_for_ai returns messages ordered by created_at" do
    @conversation.save!
    older = @conversation.messages.create!(role: "user", content: "First", created_at: 2.minutes.ago)
    newer = @conversation.messages.create!(role: "assistant", content: "Second", created_at: 1.minute.ago)
    result = @conversation.messages_for_ai
    assert_equal older.content, result.first[:content]
    assert_equal newer.content, result.last[:content]
  end
end
