require "test_helper"

# Tests for the streaming accumulation and save logic in create_streaming.
#
# ActionController::Live runs the action in a child thread that commits the
# response before the action body finishes, so post(...) returns before the
# DB write happens. Testing through the HTTP stack produces a race condition.
# Instead we test the controller's private logic directly by calling the method
# on a minimal controller instance with all I/O stubbed out.
class Api::MessagesControllerTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(email: "test@example.com", password: "password123")
    @conversation = @user.conversations.create!(title: "Test Chat")
    @conversation.messages.create!(role: "user", content: "Hello")
  end

  def teardown
    Message.delete_all
    Conversation.delete_all
    User.delete_all
  end

  # Build a minimal controller instance with enough stubbing to run
  # create_streaming without a real request or response stream.
  def build_controller(conversation)
    controller = Api::MessagesController.new
    user = @user

    # Stub authentication and user lookup
    controller.define_singleton_method(:authenticate_api_user!) { }
    controller.define_singleton_method(:current_api_user) { user }

    # Stub params
    controller.define_singleton_method(:params) do
      ActionController::Parameters.new(
        conversation_id: conversation.id,
        content: "Hello",
        regenerating: true
      )
    end

    # Stub response stream — writes are no-ops, close is a no-op
    fake_stream = Object.new
    fake_stream.define_singleton_method(:write) { |_data| }
    fake_stream.define_singleton_method(:close) { }

    fake_response = Object.new
    fake_response.define_singleton_method(:headers) { Hash.new }
    fake_response.define_singleton_method(:stream) { fake_stream }

    controller.define_singleton_method(:response) { fake_response }

    controller
  end

  test "create_streaming saves accumulated content when client disconnects mid-stream" do
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
    end

    ChatService.stub(:call, full_stream) do
      assert_difference "@conversation.messages.reload.count", 1 do
        controller.create_streaming
      end
    end

    saved = @conversation.messages.where(role: "assistant").last
    assert_equal "Full response here", saved.content
  end
end
