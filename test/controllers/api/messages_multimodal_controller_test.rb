require "test_helper"
require "stringio"
require "tempfile"

module Api
  class MessagesMultimodalControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "multimodal_#{SecureRandom.hex(4)}@example.com", password: "password123")
      @headers = sign_in_as(@user)
      @conversation = @user.conversations.create!(title: "New Chat")
      @upload = uploaded_file("source", "source.png", "image/png")
    end

    teardown { @upload.tempfile.close! }

    test "multipart image-only message persists an attachment" do
      normalized = Tempfile.new([ "normalized", ".png" ])
      normalized.binmode
      normalized.write("normalized image")
      normalized.rewind
      result = ImageAttachmentProcessor::Result.new(
        tempfile: normalized,
        filename: "source.png",
        content_type: "image/png",
        width: 100,
        height: 50,
        original_filename: "source.png"
      )
      chat_result = {
        reply: "I see it",
        thinking: nil,
        tokens: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 },
        stats: nil
      }

      ImageCapabilityService.stub(:call, { image_input: "supported" }) do
        ImageAttachmentProcessor.stub(:call, [ result ]) do
          ChatService.stub(:call, chat_result) do
            post "/api/conversations/#{@conversation.id}/messages",
              params: { content: "", model_code: "local-llama", images: [ @upload ] },
              headers: @headers
          end
        end
      end

      assert_response :success
      message = @conversation.messages.reload.find_by!(role: "user")
      assert_equal "", message.content
      assert_equal 1, message.images.count
      assert_equal 100, message.images.first.metadata["width"]
      assert_equal 50, message.images.first.metadata["height"]
      assert_equal "source.png", message.images.first.metadata["original_filename"]
    end

    test "unsupported capability is rejected before persistence" do
      ImageCapabilityService.stub(:call, { image_input: "unsupported" }) do
        assert_no_difference "@conversation.messages.count" do
          post "/api/conversations/#{@conversation.id}/messages",
            params: { content: "look", model_code: "local-llama", images: [ @upload ] },
            headers: @headers
        end
      end

      assert_response :unprocessable_content
      assert_equal "image_input_unsupported", JSON.parse(response.body).dig("error", "code")
    end

    test "historical images gate later text turns on unsupported adapters" do
      existing = @conversation.messages.create!(role: "user", content: "look")
      existing.images.attach(
        io: StringIO.new("stored image"),
        filename: "stored.png",
        content_type: "image/png",
        identify: false
      )

      assert_no_difference "@conversation.messages.count" do
        post "/api/conversations/#{@conversation.id}/messages",
          params: { content: "follow up", model_code: "gpt-4o" },
          headers: @headers,
          as: :json
      end

      assert_response :unprocessable_content
      assert_equal "image_input_unsupported", JSON.parse(response.body).dig("error", "code")
    end

    private

    def uploaded_file(bytes, filename, content_type)
      tempfile = Tempfile.new([ "upload", File.extname(filename) ])
      tempfile.binmode
      tempfile.write(bytes)
      tempfile.rewind
      ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: filename,
        type: content_type
      )
    end
  end
end
