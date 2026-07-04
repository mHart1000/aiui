# frozen_string_literal: true

require "net/http"
require "json"

module TtsAdapters
  class Qwen3Adapter < BaseAdapter
    DEFAULT_URL = "http://localhost:8881"
    DEFAULT_MODEL = "qwen3-tts"
    DEFAULT_VOICE = "Cherry"

    def initialize
      @base_url = ENV.fetch("QWEN3_TTS_URL", DEFAULT_URL)
      @model = ENV.fetch("QWEN3_TTS_MODEL", DEFAULT_MODEL)
    end

    # Synthesizes text using a Qwen3 TTS server exposing the
    # OpenAI-compatible speech API
    # @param text [String] The text to synthesize
    # @param voice [String, nil] Voice identifier (default: "Cherry")
    # @param speed [Float, nil] Playback speed multiplier (default: 1.0)
    # @return [String] Raw audio bytes
    def synthesize(text:, voice: nil, speed: nil)
      uri = URI("#{@base_url}/v1/audio/speech")

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = {
        model: @model,
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
        raise "Qwen3 TTS request failed: #{response.code} #{response.message}"
      end

      response.body
    end

    # Returns list of available Qwen3 voices
    # @return [Array<String>] Array of voice identifiers
    def voices
      uri = URI("#{@base_url}/v1/audio/voices")

      response = Net::HTTP.get_response(uri)

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn "Failed to fetch Qwen3 voices: #{response.code}"
        return default_voices
      end

      data = JSON.parse(response.body)
      voices = data["voices"]

      if voices.is_a?(Array)
        voices.map { |v| v.is_a?(Hash) ? v["voice_id"] : v }.compact
      else
        default_voices
      end
    rescue StandardError => e
      Rails.logger.warn "Error fetching Qwen3 voices: #{e.message}"
      default_voices
    end

    # Checks if the Qwen3 server is available
    # @return [Boolean] true if server responds successfully
    def available?
      uri = URI("#{@base_url}/v1/audio/voices")
      response = Net::HTTP.get_response(uri)
      response.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      Rails.logger.debug "Qwen3 TTS not available: #{e.message}"
      false
    end

    private

    # Fallback voice list; confirm IDs against the running server
    def default_voices
      %w[
        Cherry
        Ethan
        Chelsie
        Serena
      ]
    end
  end
end
