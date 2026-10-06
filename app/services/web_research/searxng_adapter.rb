require "net/http"
require "timeout"
require "uri"

module WebResearch
  class SearxngAdapter
    MAX_RESULTS = 5
    MAX_RESPONSE_BYTES = 524_288
    MAX_TITLE_LENGTH = 500
    MAX_SNIPPET_LENGTH = 3_000
    MAX_DATE_LENGTH = 100

    class Error < StandardError; end

    class SearchResults < Array
      attr_reader :engine_failures

      def initialize(results, engine_failures:)
        super(results)
        @engine_failures = engine_failures
      end
    end

    def initialize(base_url: ENV["SEARXNG_URL"])
      configured_adapter = ENV.fetch("WEB_SEARCH_ADAPTER", "searxng")
      raise Error, "unsupported web search adapter" unless configured_adapter == "searxng"

      @base_url = base_url.presence
    end

    def search(query, count: MAX_RESULTS, deadline: monotonic_now + 20)
      raise Error, "SearXNG is not configured" unless @base_url

      uri = URI.join(@base_url.end_with?("/") ? @base_url : "#{@base_url}/", "search")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request["Accept-Encoding"] = "identity"
      request.body = URI.encode_www_form(q: query, format: "json")

      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = [ 3, remaining_seconds(deadline) ].min
      http.read_timeout = [ 5, remaining_seconds(deadline) ].min
      body = +""
      response = Timeout.timeout(remaining_seconds(deadline), Error, "SearXNG response timed out") do
        http.request(request) do |res|
          res.read_body do |chunk|
            body << chunk
            raise Error, "SearXNG response was too large" if body.bytesize > MAX_RESPONSE_BYTES
            raise Error, "SearXNG response timed out" if monotonic_now >= deadline
          end
        end
      end
      raise Error, "SearXNG returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      json = JSON.parse(body)
      raise Error, "SearXNG returned malformed results" unless json.is_a?(Hash) && json["results"].is_a?(Array)

      engine_failures = json.fetch("unresponsive_engines", [])
      raise Error, "SearXNG returned malformed engine diagnostics" unless engine_failures.is_a?(Array)

      if engine_failures.any?
        AuditLog.warn("search_engine_failed", query: query, engine_failures: engine_failures)
      end
      results = json["results"].first([ count, MAX_RESULTS ].min).filter_map { |item| normalize(item) }
      AuditLog.info("search_provider_response", query: query, raw_result_count: json["results"].length,
        usable_result_count: results.length, engine_failures: engine_failures)
      SearchResults.new(results, engine_failures: engine_failures)
    rescue JSON::ParserError
      raise Error, "SearXNG returned invalid JSON"
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::ProtocolError, SocketError, OpenSSL::SSL::SSLError, EOFError, IOError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT => e
      raise Error, e.message
    rescue URI::InvalidURIError => e
      raise Error, "invalid SearXNG URL: #{e.message}"
    end

    private

    def normalize(item)
      unless item.is_a?(Hash)
        AuditLog.warn("search_result_rejected", reason: "result is not an object")
        return nil
      end

      url = ToolRequest.new({ "urls" => [ item["url"] ] }, last_four_user_messages: item["url"]).urls.first
      unless url
        AuditLog.warn("search_result_rejected", reason: "result has no usable URL")
        return nil
      end

      { title: truncate(item["title"].to_s.strip.presence || URI(url).host, MAX_TITLE_LENGTH), url: url,
        snippet: truncate(item["content"].to_s.strip, MAX_SNIPPET_LENGTH),
        published_at: truncate(item["publishedDate"].to_s.strip.presence, MAX_DATE_LENGTH) }
    rescue ToolRequest::InvalidRequest, URI::InvalidURIError => e
      AuditLog.warn("search_result_rejected", error_class: e.class.name, error: e.message,
        exception: e.full_message)
      nil
    end

    def truncate(value, limit)
      value&.slice(0, limit)
    end

    def remaining_seconds(deadline)
      remaining = deadline - monotonic_now
      raise Error, "SearXNG response timed out" unless remaining.positive?

      remaining
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
