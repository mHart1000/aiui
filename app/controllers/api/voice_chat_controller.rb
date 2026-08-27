module Api
  class VoiceChatController < ApplicationController
    include ActionController::Live

    before_action :require_api_user!

    # POST /api/voice_chat
    # Streams the LLM reply to `text` as one WAV stream: a single 44-byte
    # header, then continuous PCM, written as sentences are synthesized.
    def stream
      text = params.require(:text)

      service = VoiceChatStreamService.new(
        user: current_api_user,
        text: text,
        conversation_id: params[:conversation_id],
        voice: params[:voice],
        speed: params[:speed]&.to_f,
        model_code: params[:model_code]
      )

      response.headers["Content-Type"] = "audio/wav"
      response.headers["Cache-Control"] = "no-cache"
      # Prevent Rack::ETag from buffering the whole body to digest it
      response.headers["Last-Modified"] = Time.now.httpdate
      response.headers["X-Conversation-Id"] = service.conversation.id.to_s

      service.stream { |chunk| response.stream.write(chunk) }
    rescue ActionController::ParameterMissing
      render json: { error: "text is required" }, status: :bad_request
    rescue StandardError => e
      Rails.logger.error("VoiceChatController: voice chat failed: #{e.class}: #{e.message}")
      render json: { error: "Voice chat failed" }, status: :bad_gateway unless response.committed?
    ensure
      response.stream.close if response.committed?
    end

    private

    # Devise's authenticate_api_user! halts with throw(:warden), which cannot
    # cross ActionController::Live's worker thread — render a plain 401 instead.
    def require_api_user!
      return if api_user_signed_in?
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end
end
