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

  # skill resolution
  test "resolved_use_skills inherits from the user when null" do
    @conversation.save!
    @user.update!(use_skills: true)
    assert @conversation.reload.resolved_use_skills

    @user.update!(use_skills: false)
    assert_not @conversation.reload.resolved_use_skills
  end

  test "resolved_use_skills overrides the user when set" do
    @user.update!(use_skills: true)
    @conversation.use_skills = false
    @conversation.save!
    assert_not @conversation.resolved_use_skills
  end

  test "null skill_ids falls back to the user's enabled defaults" do
    @user.update!(use_skills: true)
    sql = @user.skills.create!(name: "SQL", body: "SQL BODY", enabled_by_default: true)
    @user.skills.create!(name: "Docs", body: "DOCS BODY")
    @conversation.save!

    assert_equal [ sql.id ], @conversation.resolved_skills.map(&:id)
  end

  test "explicit skill_ids override the defaults" do
    @user.update!(use_skills: true)
    @user.skills.create!(name: "SQL", body: "SQL BODY", enabled_by_default: true)
    docs = @user.skills.create!(name: "Docs", body: "DOCS BODY")
    @conversation.skill_ids = [ docs.id ]
    @conversation.save!

    assert_equal [ docs.id ], @conversation.resolved_skills.map(&:id)
  end

  test "an empty skill_ids array means none here, not inherit" do
    @user.update!(use_skills: true)
    @user.skills.create!(name: "SQL", body: "SQL BODY", enabled_by_default: true)
    @conversation.skill_ids = []
    @conversation.save!

    assert_empty @conversation.resolved_skills
  end

  test "ids of deleted skills are dropped" do
    @user.update!(use_skills: true)
    sql = @user.skills.create!(name: "SQL", body: "SQL BODY")
    @conversation.skill_ids = [ sql.id, 999_999 ]
    @conversation.save!

    assert_equal [ sql.id ], @conversation.resolved_skills.map(&:id)
  end

  test "nothing resolves when use_skills is off" do
    @user.update!(use_skills: false)
    @user.skills.create!(name: "SQL", body: "SQL BODY", enabled_by_default: true)
    @conversation.save!

    assert_empty @conversation.reload.resolved_skills
  end

  # fork_at
  test "fork_at copies messages up to and including the given one" do
    @conversation.save!
    first = @conversation.messages.create!(role: "user", content: "one")
    second = @conversation.messages.create!(role: "assistant", content: "two")
    @conversation.messages.create!(role: "user", content: "three")
    @conversation.messages.create!(role: "assistant", content: "four")

    copied = @conversation.fork_at(second).messages.order(:created_at)

    assert_equal [ "one", "two" ], copied.map(&:content)
    assert_equal [ "user", "assistant" ], copied.map(&:role)
    assert_equal first.reload.created_at, copied.first.created_at
  end

  test "fork_at carries over message metadata" do
    @conversation.save!
    @conversation.messages.create!(role: "user", content: "q")
    answer = @conversation.messages.create!(
      role: "assistant",
      content: "a",
      thinking: "hmm",
      prompt_tokens: 10,
      completion_tokens: 20,
      total_tokens: 30,
      generation_ms: 1500,
      tokens_per_second: 13.3,
      persona_version: "abc12345",
      skill_versions: { "1" => "def67890" }
    )

    copy = @conversation.fork_at(answer).messages.order(:created_at).last

    assert_equal "hmm", copy.thinking
    assert_equal 30, copy.total_tokens
    assert_equal 13.3, copy.tokens_per_second
    assert_equal 1500, copy.generation_ms
    assert_equal "abc12345", copy.persona_version
    assert_equal({ "1" => "def67890" }, copy.skill_versions)
  end

  test "fork_at leaves the source conversation untouched" do
    @conversation.save!
    @conversation.messages.create!(role: "user", content: "one")
    target = @conversation.messages.create!(role: "assistant", content: "two")
    @conversation.messages.create!(role: "user", content: "three")
    stamp = @conversation.reload.updated_at

    @conversation.fork_at(target)

    assert_equal 3, @conversation.reload.messages.count
    assert_equal stamp, @conversation.updated_at
  end

  test "fork_at copies conversation settings and keeps skills inheriting" do
    @conversation.model_code = "llama"
    @conversation.rag_enabled = true
    @conversation.save!
    message = @conversation.messages.create!(role: "user", content: "one")

    forked = @conversation.fork_at(message)

    assert_equal @user.id, forked.user_id
    assert_equal "llama", forked.model_code
    assert forked.rag_enabled
    assert_nil forked.use_skills
    assert_nil forked.skill_ids
  end

  test "fork_at prefixes the title" do
    @conversation.title = "Debugging Rails"
    @conversation.save!
    message = @conversation.messages.create!(role: "user", content: "one")

    assert_equal "(fork) Debugging Rails", @conversation.fork_at(message).title
  end

  test "fork_at does not stack the prefix when forking a fork" do
    @conversation.title = "(fork) Debugging Rails"
    @conversation.save!
    message = @conversation.messages.create!(role: "user", content: "one")

    assert_equal "(fork) Debugging Rails", @conversation.fork_at(message).title
  end

  test "fork_at keeps the placeholder title so the fork can still be auto-titled" do
    @conversation.save!
    message = @conversation.messages.create!(role: "user", content: "one")

    assert @conversation.fork_at(message).placeholder_title?
  end

  test "fork_at returns nil for a message from another conversation" do
    @conversation.save!
    other = @user.conversations.create!(title: "Other")
    stranger = other.messages.create!(role: "user", content: "one")

    assert_nil @conversation.fork_at(stranger)
  end
end
