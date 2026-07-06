# frozen_string_literal: true

require "net/http"
require "json"

module TtsAdapters
  class ChatterboxAdapter < BaseAdapter
    DEFAULT_URL = "http://localhost:8004"

    def initialize
      @base_url = ENV.fetch("CHATTERBOX_TTS_URL", DEFAULT_URL)
    end

    # Synthesizes text using a Chatterbox-TTS-Server instance
    # (OpenAI-compatible speech API)
    # @param text [String] The text to synthesize
    # @param voice [String, nil] Voice identifier; first available voice when nil
    # @param speed [Float, nil] Playback speed multiplier (default: 1.0)
    # @return [String] Raw audio bytes
    def synthesize(text:, voice: nil, speed: nil)
      uri = URI("#{@base_url}/v1/audio/speech")

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      # model and voice are required by the server's schema; voices are
      # filenames from its ./voices directory, so default to the first one
      request.body = {
        model: "chatterbox",
        input: text,
        voice: voice || voices.first,
        speed: speed || 1.0,
        response_format: "mp3"
      }.to_json

      # Generous timeout: covers model cold start and queued prefetch requests
      response = Net::HTTP.start(uri.hostname, uri.port,
                                  use_ssl: uri.scheme == "https",
                                  open_timeout: 5,
                                  read_timeout: 60) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "Chatterbox TTS request failed: #{response.code} #{response.message}"
      end

      response.body
    end

    # @return [Boolean] Chatterbox-TTS-Server supports chunked streaming
    def streaming?
      true
    end

    # Streams synthesized audio via the server's /tts endpoint:
    # one WAV header, then crossfaded PCM16 chunks as generation proceeds
    # @param text [String] The text to synthesize
    # @param voice [String, nil] Voice identifier; first available voice when nil
    # @param speed [Float, nil] Playback speed multiplier (default: 1.0)
    # @yield [String] Raw audio chunks
    def synthesize_stream(text:, voice: nil, speed: nil)
      uri = URI("#{@base_url}/tts")

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = {
        text: text,
        voice_mode: "predefined",
        predefined_voice_id: voice || voices.first,
        stream: true,
        split_text: true,
        # Small chunks so each batch's first audio arrives sooner
        chunk_size: 70,
        speed_factor: speed || 1.0
      }.to_json

      Net::HTTP.start(uri.hostname, uri.port,
                      use_ssl: uri.scheme == "https",
                      open_timeout: 5,
                      read_timeout: 60) do |http|
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            raise "Chatterbox TTS stream failed: #{response.code} #{response.message}"
          end

          response.read_body { |chunk| yield chunk }
        end
      end
    end

    # Returns list of available Chatterbox voices
    # @return [Array<String>] Array of voice identifiers
    def voices
      uri = URI("#{@base_url}/v1/audio/voices")

      response = Net::HTTP.get_response(uri)

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn "Failed to fetch Chatterbox voices: #{response.code}"
        return []
      end

      data = JSON.parse(response.body)
      voices = data.is_a?(Hash) ? data["voices"] : data

      if voices.is_a?(Array)
        voices.map { |v| v.is_a?(Hash) ? (v["voice_id"] || v["name"]) : v }.compact
      else
        []
      end
    rescue StandardError => e
      Rails.logger.warn "Error fetching Chatterbox voices: #{e.message}"
      []
    end

    # Checks if the Chatterbox server is available
    # @return [Boolean] true if server responds successfully
    def available?
      uri = URI("#{@base_url}/v1/audio/voices")
      response = Net::HTTP.get_response(uri)
      response.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      Rails.logger.debug "Chatterbox TTS not available: #{e.message}"
      false
    end
  end
end
