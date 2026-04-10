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
    assert_equal [ { role: "user", content: "Hello" } ], result
  end

  test "messages_for_ai returns messages ordered by created_at" do
    @conversation.save!
    older = @conversation.messages.create!(role: "user", content: "First", created_at: 2.minutes.ago)
    newer = @conversation.messages.create!(role: "assistant", content: "Second", created_at: 1.minute.ago)
    result = @conversation.messages_for_ai
    assert_equal older.content, result.first[:content]
    assert_equal newer.content, result.last[:content]
  end

  # add_assistant_message
  test "add_assistant_message creates a message with single-pass tokens" do
    @conversation.save!
    tokens = { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
    message = @conversation.add_assistant_message(reply: "Hello!", thinking: nil, tokens: tokens)
    assert_equal "assistant", message.role
    assert_equal "Hello!", message.content
    assert_equal 10, message.prompt_tokens
    assert_equal 5, message.completion_tokens
    assert_equal 15, message.total_tokens
  end

  test "add_assistant_message creates a message with two-pass tokens" do
    @conversation.save!
    tokens = {
      planning: { prompt_tokens: 8, completion_tokens: 4, total_tokens: 12 },
      execution: { prompt_tokens: 10, completion_tokens: 6, total_tokens: 16 },
      total: 28
    }
    message = @conversation.add_assistant_message(reply: "Hello!", thinking: "my analysis", tokens: tokens)
    assert_equal 18, message.prompt_tokens
    assert_equal 10, message.completion_tokens
    assert_equal 28, message.total_tokens
    assert_equal "my analysis", message.thinking
  end

  test "add_assistant_message defaults to zero tokens when tokens is nil" do
    @conversation.save!
    message = @conversation.add_assistant_message(reply: "Hello!", thinking: nil, tokens: nil)
    assert_equal 0, message.prompt_tokens
    assert_equal 0, message.completion_tokens
    assert_equal 0, message.total_tokens
  end

  # entitle
  test "entitle skips when title is already a real title" do
    @conversation.title = "Existing Title"
    @conversation.save!
    @conversation.entitle("some content")
    assert_equal "Existing Title", @conversation.reload.title
  end

  test "entitle updates title from ChatService reply" do
    @conversation.save!
    ChatService.stub(:call, { reply: "Rails Debugging Guide" }) do
      @conversation.entitle("How do I debug my Rails app?")
    end
    assert_equal "Rails Debugging Guide", @conversation.reload.title
  end

  test "entitle falls back to content when ChatService returns empty reply" do
    @conversation.save!
    ChatService.stub(:call, { reply: "" }) do
      @conversation.entitle("How do I debug my Rails app?")
    end
    assert_equal "How do I debug my Rails app?", @conversation.reload.title
  end

  test "entitle falls back to truncated content when ChatService raises" do
    long_content = "a" * 100
    @conversation.save!
    ChatService.stub(:call, ->(**_) { raise "API error" }) do
      @conversation.entitle(long_content)
    end
    assert_equal "a" * 41, @conversation.reload.title
  end
end
