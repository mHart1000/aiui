require "test_helper"

class Api::MessagesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(email: "test@example.com", password: "password123")
    @headers = sign_in_as(@user)
    @conversation = @user.conversations.create!(title: "Test Chat")
    @conversation.messages.create!(role: "user", content: "Hello")
  end

  # Simulate ChatService streaming some chunks then raising ClientDisconnected.
  # Returns a lambda that can be used with stub(:call, ...).
  def streaming_service_that_disconnects_after(chunks)
    lambda do |**_kwargs, &block|
      chunks.each { |chunk| block.call(chunk, :response) }
      raise ActionController::Live::ClientDisconnected
    end
  end

  test "create_streaming saves accumulated content when client disconnects mid-stream" do
    partial_chunks = [ "Hello", " world", " partial" ]

    ChatService.stub(:call, streaming_service_that_disconnects_after(partial_chunks)) do
      assert_difference "@conversation.messages.reload.count", 1 do
        post "/api/conversations/#{@conversation.id}/messages/stream",
          params: { content: "Hello", regenerating: true },
          headers: @headers,
          as: :json
      end
    end

    saved = @conversation.messages.where(role: "assistant").last
    assert_equal "Hello world partial", saved.content
  end

  test "create_streaming does not save when nothing was streamed before disconnect" do
    empty_disconnect = lambda do |**_kwargs, &block|
      raise ActionController::Live::ClientDisconnected
    end

    ChatService.stub(:call, empty_disconnect) do
      assert_no_difference "@conversation.messages.reload.count" do
        post "/api/conversations/#{@conversation.id}/messages/stream",
          params: { content: "Hello", regenerating: true },
          headers: @headers,
          as: :json
      end
    end
  end

  test "create_streaming saves full content on normal completion" do
    chunks = [ "Full", " response", " here" ]

    full_stream = lambda do |**_kwargs, &block|
      chunks.each { |chunk| block.call(chunk, :response) }
    end

    ChatService.stub(:call, full_stream) do
      assert_difference "@conversation.messages.reload.count", 1 do
        post "/api/conversations/#{@conversation.id}/messages/stream",
          params: { content: "Hello", regenerating: true },
          headers: @headers,
          as: :json
      end
    end

    saved = @conversation.messages.where(role: "assistant").last
    assert_equal "Full response here", saved.content
  end
end
