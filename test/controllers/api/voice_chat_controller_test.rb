require "test_helper"

# The streaming happy path drives the action directly with I/O stubbed out —
# see messages_controller_test.rb for why Live + real HTTP is a race. Auth and
# param validation go through the HTTP stack below.
class Api::VoiceChatControllerStreamTest < ActiveSupport::TestCase
  FAKE_WAV = ("W" * 44 + "PCM").freeze

  class FakeAdapter
    def streaming?
      false
    end

    def synthesize(text:, voice: nil, speed: nil, format: "mp3")
      FAKE_WAV
    end
  end

  setup do
    @user = User.create!(email: "voicectl@example.com", password: "password123")
  end

  teardown do
    Message.delete_all
    Conversation.delete_all
    User.delete_all
  end

  def build_controller(action_params)
    controller = Api::VoiceChatController.new
    user = @user

    controller.define_singleton_method(:current_api_user) { user }
    controller.define_singleton_method(:params) { ActionController::Parameters.new(action_params) }

    writes = []
    fake_stream = Object.new
    fake_stream.define_singleton_method(:write) { |data| writes << data }
    fake_stream.define_singleton_method(:close) { }

    headers = {}
    fake_response = Object.new
    fake_response.define_singleton_method(:headers) { headers }
    fake_response.define_singleton_method(:stream) { fake_stream }
    fake_response.define_singleton_method(:committed?) { true }

    controller.define_singleton_method(:response) { fake_response }

    [ controller, headers, writes ]
  end

  test "streams audio, sets headers, and persists both messages" do
    controller, headers, writes = build_controller(text: "Hi. Bye.")

    with_env("AI_ENABLED" => "false", "TTS_ADAPTER" => "kokoro") do
      TtsAdapters::KokoroAdapter.stub(:new, FakeAdapter.new) do
        controller.stream
      end
    end

    assert_equal "audio/wav", headers["Content-Type"]
    assert headers["Last-Modified"].present?

    conversation = Conversation.find(headers["X-Conversation-Id"].to_i)
    assert_equal %w[user assistant], conversation.messages.order(:created_at).map(&:role)
    assert_equal "Hi. Bye.", conversation.messages.order(:created_at).first.content

    audio = writes.join
    assert audio.start_with?("W" * 44), "first batch's WAV header should be relayed"
    assert_equal 1, audio.scan("W" * 44).length, "later batches' headers should be stripped"
  end
end

class Api::VoiceChatControllerAuthTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "voiceauth@example.com", password: "password123")
  end

  teardown do
    Message.delete_all
    Conversation.delete_all
    User.delete_all
  end

  test "returns 401 without a token" do
    post "/api/voice_chat", params: { text: "hello" }, as: :json
    assert_response :unauthorized
  end

  test "returns 400 when text is missing" do
    headers = sign_in_as(@user)
    post "/api/voice_chat", params: { text: "" }, headers: headers, as: :json
    assert_response :bad_request
  end
end
