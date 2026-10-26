# frozen_string_literal: true

require "net/http"
require "json"

module TtsAdapters
  # Targets the OpenAI-compatible API provided by maemreyo/omnivoice-server.
  class OmnivoiceAdapter < BaseAdapter
    DEFAULT_URL = "http://localhost:8882"
    DEFAULT_MODEL = "omnivoice"
    DEFAULT_VOICE = "auto"
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 120
    BUFFERED_PREFETCH_AHEAD = 1

    def initialize
      @base_url = ENV.fetch("OMNIVOICE_TTS_URL", DEFAULT_URL)
    end

    # Synthesizes a complete MP3. Streaming stays disabled because the server's
    # PCM stream cannot report synthesis failures after its response begins.
    def synthesize(text:, voice: nil, speed: nil)
      uri = URI("#{@base_url}/v1/audio/speech")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = {
        model: DEFAULT_MODEL,
        input: text,
        voice: voice || DEFAULT_VOICE,
        speed: speed || 1.0,
        response_format: "mp3"
      }.to_json

      response = request(uri, request)
      unless response.is_a?(Net::HTTPSuccess)
        raise "OmniVoice TTS request failed: #{response.code} #{response.message}: #{response.body}"
      end
      if response["X-No-Speech-Detected"] == "true"
        raise "OmniVoice TTS reported that synthesis produced no speech"
      end

      response.body
    end

    # Returns selectable preset, file, and cloned voices. The design entry is a
    # placeholder for free-form attributes, so it is not useful in a select box.
    def voices
      response = Net::HTTP.get_response(URI("#{@base_url}/v1/voices"))
      unless response.is_a?(Net::HTTPSuccess)
        raise "OmniVoice voices request failed: #{response.code} #{response.message}: #{response.body}"
      end

      data = JSON.parse(response.body)
      Array(data["voices"]).filter_map do |entry|
        next entry if entry.is_a?(String)
        next unless entry.is_a?(Hash)
        next if entry["type"] == "design"

        entry["id"]
      end
    end

    # The health endpoint returns 503 until the model has finished loading.
    def available?
      response = Net::HTTP.get_response(URI("#{@base_url}/health"))
      return false unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      data["ready"] == true && data["model_loaded"] == true
    rescue StandardError => e
      Rails.logger.debug "OmniVoice TTS not available: #{e.message}"
      false
    end

    # Concurrent requests contend heavily on the OmniVoice runtime.
    def buffered_prefetch_ahead
      BUFFERED_PREFETCH_AHEAD
    end

    private

    def request(uri, http_request)
      Net::HTTP.start(uri.hostname, uri.port,
                      use_ssl: uri.scheme == "https",
                      open_timeout: OPEN_TIMEOUT_SECONDS,
                      read_timeout: READ_TIMEOUT_SECONDS) do |http|
        http.request(http_request)
      end
    end
  end
end
