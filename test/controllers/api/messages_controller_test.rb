require "test_helper"

# Tests for the streaming accumulation and save logic in create_streaming.
#
# ActionController::Live runs the action in a child thread that commits the
# response before the action body finishes, so post(...) returns before the
# DB write happens. Testing through the HTTP stack produces a race condition.
# Instead we test the controller's private logic directly by calling the method
# on a minimal controller instance with all I/O stubbed out.
class Api::MessagesControllerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    @user = User.create!(email: "test@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Test Chat")
    @conversation.messages.create!(role: "user", content: "Hello")
  end

  def teardown
    Message.delete_all
    Conversation.delete_all
    Skill.delete_all
    User.delete_all
  end

  # Build a minimal controller instance with enough stubbing to run
  # create_streaming without a real request or response stream.
  def build_controller(conversation, extra_params = {}, &writer)
    controller = Api::MessagesController.new
    user = @user

    # Stub authentication and user lookup
    controller.define_singleton_method(:authenticate_api_user!) { }
    controller.define_singleton_method(:current_api_user) { user }

    # Stub params
    controller.define_singleton_method(:params) do
      ActionController::Parameters.new(
        { conversation_id: conversation.id, content: "Hello", regenerating: true }.merge(extra_params)
      )
    end

    # Stub response stream — writes are no-ops, close is a no-op
    fake_stream = Object.new
    writes = []
    fake_stream.define_singleton_method(:write) do |data|
      writes << data
      writer&.call(data)
    end
    fake_stream.define_singleton_method(:close) { }

    fake_response = Object.new
    fake_response.define_singleton_method(:headers) { Hash.new }
    fake_response.define_singleton_method(:stream) { fake_stream }

    controller.define_singleton_method(:response) { fake_response }
    controller.define_singleton_method(:stream_writes) { writes }
    controller.define_singleton_method(:render) { |json:| json }

    controller
  end

  test "create_streaming saves partial content when client disconnects" do
    controller = build_controller(@conversation)

    partial_chunks = [ "Hello", " world", " partial" ]
    disconnecting_service = lambda do |**_kwargs, &block|
      partial_chunks.each { |chunk| block.call(chunk, :response) }
      raise ActionController::Live::ClientDisconnected
    end

    ChatService.stub(:call, disconnecting_service) do
      assert_difference "@conversation.messages.reload.count", 1 do
        controller.create_streaming
      end
    end

    saved = @conversation.messages.where(role: "assistant").last
    assert_equal "Hello world partial", saved.content
  end

  test "create_streaming does not save when nothing was streamed before disconnect" do
    controller = build_controller(@conversation)

    empty_disconnect = lambda { |**_kwargs, &block| raise ActionController::Live::ClientDisconnected }

    ChatService.stub(:call, empty_disconnect) do
      assert_no_difference "@conversation.messages.reload.count" do
        controller.create_streaming
      end
    end
  end

  test "create_streaming saves full content on normal completion" do
    controller = build_controller(@conversation)

    chunks = [ "Full", " response", " here" ]
    full_stream = lambda do |**_kwargs, &block|
      chunks.each { |chunk| block.call(chunk, :response) }
      @conversation.messages.find_by!(role: "user").touch
      { persona_version: nil }
    end

    ChatService.stub(:call, full_stream) do
      assert_difference "@conversation.messages.reload.count", 1 do
        controller.create_streaming
      end
    end

    saved = @conversation.messages.where(role: "assistant").last
    assert_equal "Full response here", saved.content
    assert_match(/"type":"done"/, controller.stream_writes.last)
  end

  test "persists the assistant before emitting done" do
    persisted_before_done = false
    controller = build_controller(@conversation) do |event|
      if event.include?('"type":"done"')
        persisted_before_done = @conversation.messages.where(role: "assistant").exists?
      end
    end
    service = lambda do |**_kwargs, &block|
      block.call("saved first", :response)
      { persona_version: nil }
    end

    ChatService.stub(:call, service) { controller.create_streaming }

    assert persisted_before_done
  end

  test "disconnect after persistence does not create a duplicate assistant" do
    controller = build_controller(@conversation) do |event|
      raise ActionController::Live::ClientDisconnected if event.include?('"type":"done"')
    end
    service = lambda do |**_kwargs, &block|
      block.call("one copy", :response)
      { persona_version: nil }
    end

    ChatService.stub(:call, service) { controller.create_streaming }

    assert_equal 1, @conversation.messages.where(role: "assistant").count
    assert_equal "one copy", @conversation.messages.find_by!(role: "assistant").content
  end

  test "does not save an answer after the user turn changes during generation" do
    controller = build_controller(@conversation)
    service = lambda do |**_kwargs, &block|
      block.call("stale answer", :response)
      @conversation.messages.find_by!(role: "user").update!(content: "Edited prompt")
      { persona_version: nil }
    end

    ChatService.stub(:call, service) do
      assert_no_difference "@conversation.messages.reload.where(role: 'assistant').count" do
        controller.create_streaming
      end
    end
    assert_not controller.stream_writes.any? { |event| event.include?('"type":"done"') }
  end

  test "does not save a streamed answer when an edit commits first" do
    message = @conversation.messages.find_by!(role: "user")
    controller = build_controller(@conversation, id: message.id, content: "Edited prompt")
    signature = controller.send(:message_signature, message)
    errors = Queue.new

    edit = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { controller.update }
    rescue => error
      errors << error
    end
    edit.join

    stream = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        controller.send(
          :persist_streamed_response,
          Conversation.find(@conversation.id),
          message.id,
          signature,
          reply: "stale answer",
          thinking: "",
          entitle: false
        )
      end
    rescue => error
      errors << error
    end
    persisted = stream.value
    raise errors.pop unless errors.empty?

    assert_not persisted
    assert_equal 0, @conversation.messages.where(role: "assistant").count
  end

  test "edit removes an assistant persisted while it waits for the conversation lock" do
    message = @conversation.messages.find_by!(role: "user")
    controller = build_controller(@conversation, id: message.id, content: "Edited prompt")
    signature = controller.send(:message_signature, message)
    assistant_insert_started = Queue.new
    release_assistant_insert = Queue.new
    edit_finished = Queue.new
    errors = Queue.new

    stream = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        conversation = Conversation.find(@conversation.id)
        conversation.define_singleton_method(:add_assistant_message) do |**attributes|
          assistant_insert_started << true
          release_assistant_insert.pop
          super(**attributes)
        end
        controller.send(
          :persist_streamed_response, conversation, message.id, signature,
          reply: "old answer", thinking: "", entitle: false
        )
      end
    rescue => error
      errors << error
    end

    assistant_insert_started.pop
    edit = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        controller.update
      end
      edit_finished << true
    rescue => error
      errors << error
    end

    sleep 0.1
    assert edit_finished.empty?
    assert_equal 0, @conversation.messages.where(role: "assistant").count

    release_assistant_insert << true
    [ stream, edit ].each(&:join)
    raise errors.pop unless errors.empty?

    assert_equal "Edited prompt", @conversation.messages.find(message.id).content
    assert_equal 0, @conversation.messages.where(role: "assistant").count
  end

  test "regenerating with message_id truncates the conversation to that message" do
    first_answer = @conversation.messages.create!(role: "assistant", content: "First answer")
    @conversation.messages.create!(role: "user", content: "Follow-up")
    @conversation.messages.create!(role: "assistant", content: "Second answer")

    captured = nil
    capturing_service = lambda do |**kwargs, &block|
      captured = kwargs[:messages]
      block.call("Regenerated", :response)
      { persona_version: nil }
    end

    controller = build_controller(@conversation, message_id: first_answer.id)

    ChatService.stub(:call, capturing_service) do
      controller.create_streaming
    end

    assert_equal [ { role: "user", content: "Hello" } ], captured
    assert_equal [ "Hello", "Regenerated" ],
      @conversation.messages.reload.order(:created_at, :id).map(&:content)
  end
end
