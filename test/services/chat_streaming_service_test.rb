require "test_helper"

# Tests ChatStreamingService against a plain array sink instead of the
# fake-controller harness: ActionController::Live runs the controller action
# in a child thread, which is why these tests live here.
class ChatStreamingServiceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    @user = User.create!(email: "test@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Test Chat")
    @answering = @conversation.messages.create!(role: "user", content: "Hello")
  end

  def teardown
    Message.delete_all
    Conversation.delete_all
    Skill.delete_all
    Project.delete_all
    User.delete_all
  end

  def build_service(conversation = @conversation, answering_message = @answering, sink = ->(_event) { })
    ChatStreamingService.new(
      user: @user,
      conversation: conversation,
      answering_message: answering_message,
      model: conversation.model_code,
      images_allowed: false,
      sink: sink
    )
  end

  def capturing_sink
    events = []
    [ ->(event) { events << event }, events ]
  end

  def assert_search_mode(conversation, content, expected)
    answering = conversation.messages.create!(role: "user", content: content)
    seen = nil
    service = lambda do |**kwargs, &block|
      seen = kwargs[:web_search_mode]
      block.call("ok", :response)  # required so call doesn't raise EmptyStreamedResponseError
      {}
    end
    ChatService.stub(:call, service) do
      build_service(conversation, answering).call
    end
    assert_equal expected, seen
  end

  test "forces web search when the answering message includes the @search trigger" do
    @conversation.update!(web_search_mode: "off")
    assert_search_mode(@conversation, "Please @search the latest news", "always")
  end

  test "keeps the resolved web search mode without the trigger" do
    @conversation.update!(web_search_mode: "off")
    assert_search_mode(@conversation, "hello", "off")
    @conversation.update!(web_search_mode: "auto")
    assert_search_mode(@conversation, "hello", "auto")
    @conversation.update!(web_search_mode: "always")
    assert_search_mode(@conversation, "hello", "always")
  end

  test "ignores @search lookalikes" do
    @conversation.update!(web_search_mode: "off")
    assert_search_mode(@conversation, "@searching the issue", "off")
    assert_search_mode(@conversation, "contact user@search.com", "off")
  end

  test "each request resolves current project description without sharing sibling messages" do
    project = @user.projects.create!(name: "AIUI", description: "Original context")
    @conversation.update!(project: project)
    sibling = @user.conversations.create!(project: project)
    sibling.messages.create!(role: "user", content: "Private sibling history")
    descriptions = []
    service = lambda do |**kwargs, &block|
      descriptions << kwargs[:project_description]
      refute_includes kwargs[:messages].map { |message| message[:content] }, "Private sibling history"
      block.call("Answer", :response)
      {}
    end
    ChatService.stub(:call, service) do
      build_service.call
      project.update!(description: "Updated context")
      build_service.call
      @conversation.update!(project: nil)
      build_service.call
    end
    assert_equal [ "Original context", "Updated context", nil ], descriptions
  end

  test "saves partial content when client disconnects" do
    partial_chunks = [ "Hello", " world", " partial" ]
    disconnecting_service = lambda do |**_kwargs, &block|
      partial_chunks.each { |chunk| block.call(chunk, :response) }
      raise ActionController::Live::ClientDisconnected
    end

    result = ChatService.stub(:call, disconnecting_service) { build_service.call }
    assert_equal :disconnected, result[:status]
    assert result[:persisted]

    saved = @conversation.messages.where(role: "assistant").last
    assert_equal "Hello world partial", saved.content
  end

  test "does not save when nothing was streamed before disconnect" do
    empty_disconnect = lambda { |**_kwargs, &block| raise ActionController::Live::ClientDisconnected }

    result = ChatService.stub(:call, empty_disconnect) { build_service.call }
    assert_equal :disconnected, result[:status]
    assert_not result[:persisted]
    assert_nil @conversation.messages.where(role: "assistant").last
  end

  test "saves full content on normal completion" do
    chunks = [ "Full", " response", " here" ]
    full_stream = lambda do |**_kwargs, &block|
      chunks.each { |chunk| block.call(chunk, :response) }
      @conversation.messages.find_by!(role: "user").touch
      { persona_version: nil }
    end

    result = ChatService.stub(:call, full_stream) { build_service.call }
    assert_equal :done, result[:status]

    saved = @conversation.messages.where(role: "assistant").last
    assert_equal "Full response here", saved.content
  end

  test "emits web research events with their stage data" do
    @conversation.update!(web_search_level: "high", web_search_timing: "medium", web_search_query_count: 1, web_search_time_range: "custom",
      web_search_start_date: Date.new(2019, 1, 1), web_search_end_date: Date.new(2023, 12, 31))
    research = { status: "complete", provider: "searxng", queries: [ "latest news" ], sources: [] }
    service = lambda do |**kwargs, &block|
      assert_equal "high", kwargs[:web_search_level]
      assert_equal "medium", kwargs[:web_search_timing]
      assert_equal 1, kwargs[:web_search_query_count]
      assert_equal "custom", kwargs[:web_search_time_range]
      assert_equal Date.new(2019, 1, 1), kwargs[:web_search_start_date]
      assert_equal Date.new(2023, 12, 31), kwargs[:web_search_end_date]
      block.call({ stage: :searching, queries: research[:queries] }, :web_search)
      block.call("Answer", :response)
      { persona_version: nil, web_search_data: research }
    end

    sink, events = capturing_sink
    ChatService.stub(:call, service) { build_service(@conversation, @answering, sink).call }

    event = events.find { |e| e[:type] == "web_search" }
    assert_equal :searching, event[:stage]
    assert_equal [ "latest news" ], event[:queries]
    assert_equal research, @conversation.messages.where(role: "assistant").last.web_search_data.symbolize_keys
  end

  test "emits an error event and returns the original exception on failure" do
    failing_service = lambda do |**_kwargs, &block|
      block.call({ stage: :complete, status: "complete", queries: [ "latest news" ] }, :web_search)
      raise AiAdapters::LlamaAdapter::Error, "local model stopped unexpectedly"
    end

    sink, events = capturing_sink
    result = ChatService.stub(:call, failing_service) { build_service(@conversation, @answering, sink).call }

    assert_equal :failed, result[:status]
    assert_kind_of AiAdapters::LlamaAdapter::Error, result[:error]
    event = events.find { |e| e[:type] == "error" }
    assert_equal "The response could not be generated. Please retry.", event[:error]
  end

  test "reports a completed model stream with no content as a failure" do
    empty_stream = lambda do |**_kwargs, &_block|
      { finish_reason: "stop", tokens: { completion_tokens: 1 } }
    end

    sink, events = capturing_sink
    result = ChatService.stub(:call, empty_stream) { build_service(@conversation, @answering, sink).call }

    assert_equal :failed, result[:status]
    error = result[:error]
    assert_kind_of ChatStreamingService::EmptyStreamedResponseError, error
    assert_includes error.message, 'finish_reason="stop"'
    assert_includes error.message, "completion_tokens=1"

    event = events.find { |e| e[:type] == "error" }
    assert_equal "The model returned no response content. Please retry.", event[:error]
    refute events.any? { |e| e[:type] == "done" }
    assert_not @conversation.messages.where(role: "assistant").exists?
  end

  test "emits trailing stats and metadata events before done" do
    service = lambda do |**_kwargs, &block|
      block.call("saved first", :response)
      {
        persona_version: "p1",
        model_label: "model-label",
        persona_label: "persona-label",
        stats: { elapsed_ms: 1234, tokens_per_second: 55.5 },
        tokens: { total_tokens: 42 }
      }
    end

    sink, events = capturing_sink
    result = ChatService.stub(:call, service) { build_service(@conversation, @answering, sink).call }
    assert_equal :done, result[:status]

    types = events.map { |e| e[:type] }
    assert_equal [ "response", "stats", "metadata", "done" ], types
    stats = events.find { |e| e[:type] == "stats" }
    assert_equal 1234, stats[:generation_ms]
    assert_equal 55.5, stats[:tokens_per_second]
    assert_equal 42, stats[:total_tokens]
    metadata = events.find { |e| e[:type] == "metadata" }
    assert_equal "model-label", metadata[:model_label]
    assert_equal "persona-label", metadata[:persona_label]
  end

  test "persists the assistant before emitting done" do
    persisted_before_done = false
    sink = ->(event) do
      if event[:type] == "done"
        persisted_before_done = @conversation.messages.where(role: "assistant").exists?
      end
    end
    service = lambda do |**_kwargs, &block|
      block.call("saved first", :response)
      { persona_version: nil }
    end

    ChatService.stub(:call, service) { build_service(@conversation, @answering, sink).call }

    assert persisted_before_done
  end

  test "disconnect after persistence does not create a duplicate assistant" do
    sink = ->(event) { raise ActionController::Live::ClientDisconnected if event[:type] == "done" }
    service = lambda do |**_kwargs, &block|
      block.call("one copy", :response)
      { persona_version: nil }
    end

    result = ChatService.stub(:call, service) { build_service(@conversation, @answering, sink).call }

    assert_equal :disconnected, result[:status]
    assert result[:persisted]
    assert_equal 1, @conversation.messages.where(role: "assistant").count
    assert_equal "one copy", @conversation.messages.find_by!(role: "assistant").content
  end

  test "reports persisted when a trailing event fails after persistence" do
    service = lambda do |**_kwargs, &block|
      block.call("done then broke", :response)
      { persona_version: nil }
    end
    sink = ->(event) { raise "sink blew up" if event[:type] == "done" }

    result = ChatService.stub(:call, service) { build_service(@conversation, @answering, sink).call }

    assert_equal :failed, result[:status]
    assert result[:persisted]
    assert_equal "done then broke", @conversation.messages.find_by!(role: "assistant").content
  end

  test "does not save an answer after the user turn changes during generation" do
    service = lambda do |**_kwargs, &block|
      block.call("stale answer", :response)
      @conversation.messages.find_by!(role: "user").update!(content: "Edited prompt")
      { persona_version: nil }
    end

    sink, events = capturing_sink
    result = ChatService.stub(:call, service) { build_service(@conversation, @answering, sink).call }

    assert_equal :stale, result[:status]
    refute events.any? { |e| e[:type] == "done" }
    assert_not @conversation.messages.where(role: "assistant").exists?
  end
end
