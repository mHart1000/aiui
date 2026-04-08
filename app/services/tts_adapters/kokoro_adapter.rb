# frozen_string_literal: true

require "net/http"
require "json"

module TtsAdapters
  class KokoroAdapter < BaseAdapter
    DEFAULT_URL = "http://localhost:8880"
    DEFAULT_VOICE = "af_heart"

    def initialize
      @base_url = ENV.fetch("KOKORO_TTS_URL", DEFAULT_URL)
    end

    # Synthesizes text using Kokoro TTS
    # @param text [String] The text to synthesize
    # @param voice [String, nil] Voice identifier (default: "af_heart")
    # @param speed [Float, nil] Playback speed multiplier (default: 1.0)
    # @return [String] Raw audio bytes
    def synthesize(text:, voice: nil, speed: nil)
      uri = URI("#{@base_url}/v1/audio/speech")

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = {
        model: "kokoro",
        input: text,
        voice: voice || DEFAULT_VOICE,
        speed: speed || 1.0,
        response_format: "mp3"
      }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port,
                                  use_ssl: uri.scheme == "https",
                                  open_timeout: 5,
                                  read_timeout: 30) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "Kokoro TTS request failed: #{response.code} #{response.message}"
      end

      response.body
    end

    # Returns list of available Kokoro voices
    # @return [Array<String>] Array of voice identifiers
    def voices
      uri = URI("#{@base_url}/v1/audio/voices")

      response = Net::HTTP.get_response(uri)

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn "Failed to fetch Kokoro voices: #{response.code}"
        return default_voices
      end

      data = JSON.parse(response.body)
      voices = data["voices"]

      if voices.is_a?(Array)
        # Extract voice_id from each voice object if structured, or use directly if strings
        voices.map { |v| v.is_a?(Hash) ? v["voice_id"] : v }.compact
      else
        default_voices
      end
    rescue StandardError => e
      Rails.logger.warn "Error fetching Kokoro voices: #{e.message}"
      default_voices
    end

    # Checks if Kokoro server is available
    # @return [Boolean] true if server responds successfully
    def available?
      uri = URI("#{@base_url}/v1/audio/voices")
      response = Net::HTTP.get_response(uri)
      response.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      Rails.logger.debug "Kokoro TTS not available: #{e.message}"
      false
    end

    private

    # Fallback list of known Kokoro voices
    def default_voices
      %w[
        af_heart
        af_nova
        af_sky
        am_adam
        am_michael
        bf_emma
        bf_isabella
        bm_george
        bm_lewis
      ]
    end
  end
end
