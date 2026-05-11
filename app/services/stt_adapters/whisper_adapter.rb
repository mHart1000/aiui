# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module SttAdapters
  class WhisperAdapter < BaseAdapter
    DEFAULT_URL = "http://127.0.0.1:8878"

    def initialize
      @base_url = ENV.fetch("WHISPER_SERVER_URL", DEFAULT_URL)
    end

    # Transcribes an audio file via whisper-server.
    # @param audio_path [String] Absolute path to an audio file (any format whisper-server can read)
    # @return [String] Transcribed text
    def transcribe(audio_path:)
      uri = URI("#{@base_url}/inference")
      request = Net::HTTP::Post.new(uri)

      File.open(audio_path, "rb") do |io|
        request.set_form(
          [
            [ "file", io, { filename: File.basename(audio_path) } ],
            [ "response_format", "json" ]
          ],
          "multipart/form-data"
        )

        response = Net::HTTP.start(uri.hostname, uri.port,
                                   open_timeout: 5,
                                   read_timeout: 120) do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise "whisper-server request failed: #{response.code} #{response.message} (#{response.body&.slice(0, 200)})"
        end

        parsed = JSON.parse(response.body)
        (parsed["text"] || "").strip
      end
    end

    # Checks if whisper-server is reachable.
    # @return [Boolean] true if the server responds successfully
    def available?
      uri = URI("#{@base_url}/")
      response = Net::HTTP.start(uri.hostname, uri.port,
                                 open_timeout: 2,
                                 read_timeout: 2) do |http|
        http.head(uri.path.presence || "/")
      end
      response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
    rescue StandardError => e
      Rails.logger.debug "whisper-server not available: #{e.message}"
      false
    end
  end
end
