require "uri"
require "set"

module WebResearch
  class ToolRequest
    TOOL_NAME = "research_web".freeze
    MAX_QUERIES = 2
    MAX_URLS = 3
    MAX_QUERY_LENGTH = 240

    class InvalidRequest < StandardError; end

    attr_reader :queries, :urls

    def self.parse!(tool_calls:, latest_user_content:)
      calls = Array(tool_calls)
      raise InvalidRequest, "expected exactly one web research request" unless calls.length == 1

      call = calls.first
      function = call.is_a?(Hash) ? (call["function"] || call[:function] || call) : nil
      name = function&.dig("name") || function&.dig(:name)
      raise InvalidRequest, "unknown research tool" unless name == TOOL_NAME

      arguments = function["arguments"] || function[:arguments]
      parsed = arguments.is_a?(String) ? JSON.parse(arguments) : arguments
      raise InvalidRequest, "tool arguments must be an object" unless parsed.is_a?(Hash)

      new(parsed, latest_user_content: latest_user_content)
    rescue JSON::ParserError
      raise InvalidRequest, "tool arguments were not valid JSON"
    end

    def initialize(arguments, latest_user_content:)
      @queries = normalize_queries(arguments["queries"] || arguments[:queries])
      @urls = normalize_urls(arguments["urls"] || arguments[:urls], latest_user_content)
      raise InvalidRequest, "research request was empty" if @queries.empty? && @urls.empty?
    end

    private

    def normalize_queries(values)
      raise InvalidRequest, "queries must be an array" if values.present? && !values.is_a?(Array)

      values = Array(values)
      raise InvalidRequest, "too many search queries" if values.length > MAX_QUERIES

      values.map do |value|
        query = value.to_s.strip
        if query.empty? || query.length > MAX_QUERY_LENGTH || query.match?(/[\u0000-\u001f\u007f]/)
          raise InvalidRequest, "invalid search query"
        end
        query
      end.uniq
    end

    def normalize_urls(values, latest_user_content)
      raise InvalidRequest, "URLs must be an array" if values.present? && !values.is_a?(Array)

      values = Array(values)
      raise InvalidRequest, "too many direct URLs" if values.length > MAX_URLS

      user_urls = latest_user_content.to_s.scan(%r{https?://[^\s<>"']+}i).filter_map { |url| normalize_url(url) }.to_set
      values.map do |value|
        normalized = normalize_url(value)
        raise InvalidRequest, "invalid direct URL" unless normalized
        raise InvalidRequest, "direct URL was not supplied by the user" unless user_urls.include?(normalized)
        normalized
      end.uniq
    end

    def normalize_url(value)
      uri = URI.parse(value.to_s.strip)
      return nil unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?
      return nil unless [ 80, 443 ].include?(uri.port)

      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end
  end
end
