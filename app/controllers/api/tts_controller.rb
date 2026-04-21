# frozen_string_literal: true

module Api
  class TtsController < ApplicationController
    # POST /api/tts/synthesize
    # Synthesizes text to speech and returns audio bytes
    #
    # Parameters:
    #   - text: The text to synthesize (required)
    #   - voice: Voice identifier (optional, default: "af_heart")
    #   - speed: Playback speed multiplier (optional, default: 1.0)
    #
    # Returns: audio/mpeg binary data
    def synthesize
      text = params.require(:text)

      if text.blank?
        render json: { error: "Text cannot be empty" }, status: :bad_request
        return
      end

      audio = TextToSpeechService.call(
        text: text,
        voice: params[:voice],
        speed: params[:speed]&.to_f
      )

      send_data audio, type: "audio/mpeg", disposition: "inline"
    rescue ActionController::ParameterMissing => e
      render json: { error: e.message }, status: :bad_request
    rescue StandardError => e
      Rails.logger.error "TTS synthesis failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: "TTS synthesis failed" }, status: :internal_server_error
    end

    # GET /api/tts/voices
    # Returns list of available voices
    #
    # Returns: { voices: ["af_heart", "af_nova", ...] }
    def voices
      voice_list = TextToSpeechService.voices
      render json: { voices: voice_list }
    rescue StandardError => e
      Rails.logger.error "Failed to fetch TTS voices: #{e.message}"
      render json: { voices: [] }
    end

    # GET /api/tts/status
    # Checks if TTS service is available
    #
    # Returns: { available: true/false }
    def status
      available = TextToSpeechService.available?
      render json: { available: available }
    rescue StandardError => e
      Rails.logger.error "TTS status check failed: #{e.message}"
      render json: { available: false }
    end
  end
end
