require "net/http"
require "uri"

module WebResearch
  class SearxngAdapter
    MAX_RESULTS = 5

    class Error < StandardError; end

    def initialize(base_url: ENV["SEARXNG_URL"])
      @base_url = base_url.presence
    end

    def search(query, count: MAX_RESULTS)
      raise Error, "SearXNG is not configured" unless @base_url

      uri = URI.join(@base_url.end_with?("/") ? @base_url : "#{@base_url}/", "search")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = URI.encode_www_form(q: query, format: "json")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 3
      http.read_timeout = 5
      response = http.request(request)
      raise Error, "SearXNG returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      json = JSON.parse(response.body)
      Array(json["results"]).first([ count, MAX_RESULTS ].min).filter_map { |item| normalize(item) }
    rescue JSON::ParserError
      raise Error, "SearXNG returned invalid JSON"
    rescue URI::InvalidURIError => e
      raise Error, "invalid SearXNG URL: #{e.message}"
    end

    private

    def normalize(item)
      url = ToolRequest.new({ "urls" => [ item["url"] ] }, latest_user_content: item["url"]).urls.first
      return nil unless url

      { title: item["title"].to_s.strip.presence || URI(url).host, url: url,
        snippet: item["content"].to_s.strip, published_at: item["publishedDate"].presence }
    rescue ToolRequest::InvalidRequest, URI::InvalidURIError
      nil
    end
  end
end
