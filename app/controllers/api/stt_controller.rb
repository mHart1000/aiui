# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Api
  class SttController < ApplicationController
    before_action :authenticate_api_user!

    UPLOAD_DIR = Rails.root.join("tmp", "stt_uploads").freeze
    MAX_BYTES = 25 * 1024 * 1024 # 25 MB

    # POST /api/stt/transcribe
    # Transcribes an uploaded audio file to text.
    #
    # Parameters:
    #   - audio: Multipart file upload (required). Any format ffmpeg can read.
    #
    # Returns: { text: "transcribed text" }
    def transcribe
      file = params[:audio]
      unless file.respond_to?(:tempfile) && file.respond_to?(:original_filename)
        return render json: { error: "missing audio file" }, status: :bad_request
      end

      if file.size > MAX_BYTES
        return render json: { error: "audio file exceeds #{MAX_BYTES / 1024 / 1024} MB limit" }, status: :payload_too_large
      end

      FileUtils.mkdir_p(UPLOAD_DIR)
      ext = File.extname(file.original_filename.to_s)
      upload_path = UPLOAD_DIR.join("#{SecureRandom.uuid}#{ext}").to_s
      FileUtils.cp(file.tempfile.path, upload_path)

      text = SpeechToTextService.call(audio_path: upload_path)
      render json: { text: text }
    rescue StandardError => e
      Rails.logger.error "STT transcription failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { error: "STT transcription failed" }, status: :internal_server_error
    ensure
      File.delete(upload_path) if upload_path && File.exist?(upload_path)
    end
  end
end
