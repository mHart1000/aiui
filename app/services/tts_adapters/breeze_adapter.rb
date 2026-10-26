# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"

module TtsAdapters
  # Targets the official Breeze TTS 2 single-concurrency streaming API.
  class BreezeAdapter < BaseAdapter
    DEFAULT_URL = "http://localhost:7860"
    DEFAULT_VOICE = "breeze_default"
    DEFAULT_INSTRUCTION = "A warm, natural adult woman with clear conversational delivery."
    DEFAULT_CFG_SCALE = 4.0
    DEFAULT_SEED = 42
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 120
    SAMPLE_RATE = 24_000
    CHANNELS = 1
    BITS_PER_SAMPLE = 16
    BYTES_PER_SAMPLE = BITS_PER_SAMPLE / 8
    BUFFERED_PREFETCH_AHEAD = 1
    UNKNOWN_WAV_LENGTH = 0xffffffff

    def initialize
      @base_url = ENV.fetch("BREEZE_TTS_URL", DEFAULT_URL)
      @voice = ENV.fetch("BREEZE_TTS_VOICE", DEFAULT_VOICE)
      @instruction = ENV.fetch("BREEZE_TTS_INSTRUCTION", DEFAULT_INSTRUCTION)
      @cfg_scale = Float(ENV.fetch("BREEZE_TTS_CFG_SCALE", DEFAULT_CFG_SCALE))
      @seed = Integer(ENV.fetch("BREEZE_TTS_SEED", DEFAULT_SEED))

      raise ArgumentError, "BREEZE_TTS_CFG_SCALE must be greater than 0" unless @cfg_scale.positive?
    end

    # Returns a complete WAV assembled from the server's raw PCM stream.
    def synthesize(text:, voice: nil, speed: nil)
      validate_voice!(voice)
      response = perform_request(speech_request(text))
      unless response.is_a?(Net::HTTPSuccess)
        raise provider_error("request", response)
      end
      raise "Breeze TTS synthesis produced no audio" if response.body.blank?

      wav_header(response.body.bytesize) + response.body
    end

    def streaming?
      true
    end

    # The server accepts one inference request and explicitly rejects competitors.
    def buffered_prefetch_ahead
      BUFFERED_PREFETCH_AHEAD
    end

    # Prepends the fixed Breeze PCM format as WAV, then forwards PCM progressively.
    def synthesize_stream(text:, voice: nil, speed: nil)
      validate_voice!(voice)
      request = speech_request(text)

      Net::HTTP.start(request.uri.hostname, request.uri.port,
                      use_ssl: request.uri.scheme == "https",
                      open_timeout: OPEN_TIMEOUT_SECONDS,
                      read_timeout: READ_TIMEOUT_SECONDS) do |http|
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            response_body = +""
            response.read_body { |chunk| response_body << chunk }
            raise provider_error("stream", response, response_body)
          end

          yielded_audio = false
          yield wav_header
          response.read_body do |chunk|
            next if chunk.empty?

            yielded_audio = true
            yield chunk
          end
          raise "Breeze TTS stream produced no audio" unless yielded_audio
        end
      end
    end

    # Breeze voice design is configured locally; the server has no voice-list endpoint.
    def voices
      [ @voice ]
    end

    # The model endpoint becomes available only after the checkpoint has loaded.
    def available?
      response = Net::HTTP.get_response(URI("#{@base_url}/v1/model"))
      return false unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)["frame_rate"].to_f.positive?
    rescue StandardError => e
      Rails.logger.debug "Breeze TTS not available: #{e.message}"
      false
    end

    private

    def speech_request(text)
      uri = URI("#{@base_url}/v1/audio/speech")
      request = Net::HTTP::Post.new(uri)
      boundary = "aiui-breeze-#{SecureRandom.hex(12)}"
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request.body = multipart_body(boundary, {
        text: text,
        instruction: @instruction,
        cfg_scale: @cfg_scale,
        seed: @seed
      })
      request
    end

    def multipart_body(boundary, fields)
      fields.flat_map do |name, value|
        [
          "--#{boundary}\r\n",
          "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n",
          value.to_s,
          "\r\n"
        ]
      end.join + "--#{boundary}--\r\n"
    end

    def perform_request(request)
      Net::HTTP.start(request.uri.hostname, request.uri.port,
                      use_ssl: request.uri.scheme == "https",
                      open_timeout: OPEN_TIMEOUT_SECONDS,
                      read_timeout: READ_TIMEOUT_SECONDS) do |http|
        http.request(request)
      end
    end

    def validate_voice!(voice)
      return if voice.blank? || voice == @voice

      raise ArgumentError, "Unknown Breeze voice #{voice.inspect}; configured voice is #{@voice.inspect}"
    end

    def provider_error(operation, response, body = response.body)
      RuntimeError.new(
        "Breeze TTS #{operation} failed: #{response.code} #{response.message}: #{body}"
      )
    end

    def wav_header(data_bytes = nil)
      data_size = data_bytes || UNKNOWN_WAV_LENGTH
      riff_size = data_bytes ? 36 + data_bytes : UNKNOWN_WAV_LENGTH
      byte_rate = SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE
      block_align = CHANNELS * BYTES_PER_SAMPLE

      "RIFF".b + [ riff_size ].pack("V") + "WAVEfmt ".b +
        [ 16, 1, CHANNELS, SAMPLE_RATE, byte_rate, block_align, BITS_PER_SAMPLE ].pack("VvvVVvv") +
        "data".b + [ data_size ].pack("V")
    end
  end
end
