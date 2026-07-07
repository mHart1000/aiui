# frozen_string_literal: true

module Api
  class TtsStreamController < ApplicationController
    include ActionController::Live

    # POST /api/tts/stream
    # Streams synthesized audio as chunked audio/wav
    #
    # Parameters:
    #   - text: The text to synthesize (required)
    #   - voice: Voice identifier (optional)
    #   - speed: Playback speed multiplier (optional, default: 1.0)
    def stream
      text = params.require(:text)

      if text.blank?
        render json: { error: "Text cannot be empty" }, status: :bad_request
        return
      end

      unless TextToSpeechService.streaming?
        render json: { error: "Active TTS adapter does not support streaming" },
               status: :unprocessable_entity
        return
      end

      response.headers["Content-Type"] = "audio/wav"
      response.headers["Cache-Control"] = "no-cache"
      # Prevent Rack::ETag from buffering the whole body to digest it
      response.headers["Last-Modified"] = Time.now.httpdate

      TextToSpeechService.stream(
        text: text,
        voice: params[:voice],
        speed: params[:speed]&.to_f
      ) { |chunk| response.stream.write(chunk) }
    rescue ActionController::ParameterMissing => e
      render json: { error: e.message }, status: :bad_request
    rescue StandardError => e
      Rails.logger.error "TTS streaming failed: #{e.message}"
      # Headers may already be sent; just stop the stream
    ensure
      response.stream.close if response.committed?
    end
  end
end
