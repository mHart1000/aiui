require "net/http"

class LlamaCapabilities
  SUCCESS_TTL = 60.seconds
  UNKNOWN_TTL = 10.seconds

  class << self
    def image_input(refresh: false)
      reset! if refresh
      return @image_input if @image_input && @expires_at && monotonic_now < @expires_at

      @image_input = fetch_image_input
      ttl = @image_input == "unknown" ? UNKNOWN_TTL : SUCCESS_TTL
      @expires_at = monotonic_now + ttl
      @image_input
    end

    def vision?
      image_input == "supported"
    end

    def reset!
      @image_input = nil
      @expires_at = nil
    end

    private

    def fetch_image_input
      uri = URI("#{base_url}/props")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 2
      http.read_timeout = 2
      response = http.get(uri.request_uri)
      raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      vision = JSON.parse(response.body).dig("modalities", "vision")
      return "supported" if vision == true
      return "unsupported" if vision == false

      "unknown"
    rescue => e
      Rails.logger.warn("LlamaCapabilities: /props lookup failed (#{e.class}: #{e.message})")
      "unknown"
    end

    def base_url
      (ENV["LLAMA_API_URL"] || "http://localhost:8080/v1").sub(%r{/v1/?\z}, "")
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
