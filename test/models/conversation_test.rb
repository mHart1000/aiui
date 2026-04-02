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
end
