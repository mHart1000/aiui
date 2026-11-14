require "test_helper"

# Tests for create_streaming's controller-level wiring: turn setup, error
# propagation, and the edit-vs-persist race against update.
#
# ActionController::Live runs the action in a child thread that commits the
# response before the action body finishes, so post(...) returns before the
# DB write happens. Testing through the HTTP stack produces a race condition.
# Instead we test the controller directly by calling the method on a minimal
# controller instance with all I/O stubbed out.
#
# Turn orchestration (accumulation, event protocol, persistence) is covered in
# ChatStreamingServiceTest, which tests the service against a plain sink.
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
    Project.delete_all
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

  def build_service(conversation, answering_message)
    ChatStreamingService.new(
      user: @user,
      conversation: conversation,
      answering_message: answering_message,
      model: conversation.model_code,
      images_allowed: false,
      sink: ->(_event) { }
    )
  end

  test "create_streaming forces web search when regenerating a message with the trigger" do
    @conversation.update!(web_search_mode: "off")
    @conversation.messages.create!(role: "user", content: "@search weather")
    seen = nil
    service = lambda do |**kwargs, &block|
      seen = kwargs[:web_search_mode]
      block.call("ok", :response)
      {}
    end
    ChatService.stub(:call, service) do
      build_controller(@conversation, regenerating: true).create_streaming
    end
    assert_equal "always", seen
  end

  test "create_streaming sends an error event and re-raises an unexpected streaming failure" do
    controller = build_controller(@conversation)
    failing_service = lambda do |**_kwargs, &block|
      block.call({ stage: :complete, status: "complete", queries: [ "latest news" ] }, :web_search)
      raise AiAdapters::LlamaAdapter::Error, "local model stopped unexpectedly"
    end

    ChatService.stub(:call, failing_service) do
      error = assert_raises(AiAdapters::LlamaAdapter::Error) { controller.create_streaming }
      assert_equal "local model stopped unexpectedly", error.message
    end

    event = controller.stream_writes.map { |write| JSON.parse(write.delete_prefix("data: ")) }.find { |data| data["type"] == "error" }
    assert_equal "The response could not be generated. Please retry.", event["error"]
  end

  test "does not save a streamed answer when an edit commits first" do
    message = @conversation.messages.find_by!(role: "user")
    controller = build_controller(@conversation, id: message.id, content: "Edited prompt")
    signature = ChatStreamingService.message_signature(message)
    errors = Queue.new

    edit = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { controller.update }
    rescue => error
      errors << error
    end
    edit.join

    service = build_service(@conversation, message)
    stream = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service.persist_streamed_response(
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
    signature = ChatStreamingService.message_signature(message)
    assistant_insert_started = Queue.new
    release_assistant_insert = Queue.new
    edit_finished = Queue.new
    errors = Queue.new

    service = build_service(@conversation, message)
    stream = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        conversation = Conversation.find(@conversation.id)
        conversation.define_singleton_method(:add_assistant_message) do |**attributes|
          assistant_insert_started << true
          release_assistant_insert.pop
          super(**attributes)
        end
        service.persist_streamed_response(
          conversation, message.id, signature,
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
