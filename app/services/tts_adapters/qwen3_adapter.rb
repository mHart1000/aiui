# frozen_string_literal: true

require "net/http"
require "json"

module TtsAdapters
  # Targets faster-qwen3-tts's examples/openai_server.py (CUDA-graph serving).
  # It exposes only POST /v1/audio/speech and GET /health — no voices endpoint —
  # and clones a voice from a reference clip configured server-side.
  # See docs/faster-qwen3-tts-spec.md.
  class Qwen3Adapter < BaseAdapter
    DEFAULT_URL = "http://localhost:8881"
    DEFAULT_MODEL = "qwen3-tts"
    DEFAULT_VOICES = %w[aiden].freeze

    def initialize
      @base_url = ENV.fetch("QWEN3_TTS_URL", DEFAULT_URL)
      # Cosmetic: the served model is fixed by the server's --model flag; the
      # request's model field is ignored by the OpenAI-compatible endpoint.
      @model = ENV.fetch("QWEN3_TTS_MODEL", DEFAULT_MODEL)
    end

    # Synthesizes text via the OpenAI-compatible speech API (non-streaming MP3)
    # @param text [String] The text to synthesize
    # @param voice [String, nil] Voice name matching a server-side voices.json key
    # @param speed [Float, nil] Accepted but not applied by this server
    # @return [String] Raw audio bytes
    def synthesize(text:, voice: nil, speed: nil)
      uri = URI("#{@base_url}/v1/audio/speech")

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = speech_body(text, voice, speed, "mp3").to_json

      response = Net::HTTP.start(uri.hostname, uri.port,
                                  use_ssl: uri.scheme == "https",
                                  open_timeout: 5,
                                  read_timeout: 120) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "Qwen3 TTS request failed: #{response.code} #{response.message}"
      end

      response.body
    end

    # @return [Boolean] faster-qwen3-tts streams wav/pcm as it generates
    def streaming?
      true
    end

    # Streams synthesized audio: one WAV header, then PCM16 chunks. The server
    # auto-streams whenever response_format is wav/pcm (no stream flag).
    # @param text [String] The text to synthesize
    # @param voice [String, nil] Voice name matching a server-side voices.json key
    # @param speed [Float, nil] Accepted but not applied by this server
    # @yield [String] Raw audio chunks
    def synthesize_stream(text:, voice: nil, speed: nil)
      uri = URI("#{@base_url}/v1/audio/speech")

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = speech_body(text, voice, speed, "wav").to_json

      Net::HTTP.start(uri.hostname, uri.port,
                      use_ssl: uri.scheme == "https",
                      open_timeout: 5,
                      read_timeout: 60) do |http|
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            raise "Qwen3 TTS stream failed: #{response.code} #{response.message}"
          end

          response.read_body { |chunk| yield chunk }
        end
      end
    end

    # The server has no voices endpoint; voices are cloned from reference clips
    # configured at launch, so the list is supplied via config.
    # @return [Array<String>] Configured voice names (must match voices.json keys)
    def voices
      configured = ENV["QWEN3_TTS_VOICES"].to_s.split(",").map(&:strip).reject(&:empty?)
      configured.presence || DEFAULT_VOICES
    end

    # @return [Boolean] true if the server is up with the model loaded
    def available?
      response = Net::HTTP.get_response(URI("#{@base_url}/health"))
      return false unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)["model_loaded"] == true
    rescue StandardError => e
      Rails.logger.debug "Qwen3 TTS not available: #{e.message}"
      false
    end

    private

    # OpenAI /v1/audio/speech request payload
    def speech_body(text, voice, speed, format)
      {
        model: @model,
        input: text,
        voice: voice || voices.first,
        speed: speed || 1.0,
        response_format: format
      }
    end
  end
end
