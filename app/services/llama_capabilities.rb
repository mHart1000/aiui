require "net/http"

# Asks llama.cpp what it actually loaded, so swapping ggufs needs no config change.
# See docs/image-attachments-spec.md §2.5.
class LlamaCapabilities
  CACHE_TTL = 60.seconds

  class << self
    # Unknown means yes: this is a local-first app, and a visible failed request
    # beats an attach button that silently never appears. LLAMA_VISION=false opts out.
    def vision?
      props.dig("modalities", "vision") != false
    end

    def reset!
      @props = nil
      @fetched_at = nil
    end

    private

    def props
      return @props if @props && @fetched_at && Time.current - @fetched_at < CACHE_TTL

      @props = fetch_props
      @fetched_at = Time.current
      @props
    end

    def fetch_props
      uri = URI("#{base_url}/props")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 2
      http.read_timeout = 2
      JSON.parse(http.get(uri.request_uri).body)
    rescue => e
      Rails.logger.warn("LlamaCapabilities: /props unreachable (#{e.message}) — assuming vision is available")
      {}
    end

    def base_url
      (ENV["LLAMA_API_URL"] || "http://localhost:8080/v1").sub(%r{/v1/?\z}, "")
    end
  end
end
