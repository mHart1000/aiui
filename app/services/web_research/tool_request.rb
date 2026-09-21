require "uri"
require "set"

module WebResearch
  class ToolRequest
    TOOL_NAME = "research_web".freeze
    MAX_QUERIES = 2
    MAX_URLS = 3
    MAX_QUERY_LENGTH = 240
    MAX_URL_LENGTH = 2_048

    class InvalidRequest < StandardError; end

    attr_reader :queries, :urls

    def self.parse!(tool_calls:, last_four_user_messages:)
      calls = Array(tool_calls)
      raise InvalidRequest, "expected exactly one web research request, received #{calls.length}" unless calls.length == 1

      call = calls.first
      function = call.is_a?(Hash) ? (call["function"] || call[:function] || call) : nil
      name = function&.dig("name") || function&.dig(:name)
      raise InvalidRequest, "unknown research tool" unless name == TOOL_NAME

      arguments = function["arguments"] || function[:arguments]
      parsed = arguments.is_a?(String) ? JSON.parse(arguments) : arguments
      raise InvalidRequest, "tool arguments must be an object" unless parsed.is_a?(Hash)

      new(parsed, last_four_user_messages: last_four_user_messages)
    rescue JSON::ParserError
      raise InvalidRequest, "tool arguments were not valid JSON"
    end

    def initialize(arguments, last_four_user_messages:)
      unknown_keys = arguments.keys.map(&:to_s) - %w[queries urls]
      raise InvalidRequest, "tool arguments contained unknown fields" if unknown_keys.any?

      @queries = normalize_queries(arguments["queries"] || arguments[:queries])
      @urls = normalize_urls(arguments["urls"] || arguments[:urls], last_four_user_messages)
      raise InvalidRequest, "research request was empty" if @queries.empty? && @urls.empty?
    end

    private

    def normalize_queries(values)
      raise InvalidRequest, "queries must be an array" if values.present? && !values.is_a?(Array)

      values = Array(values)
      raise InvalidRequest, "too many search queries" if values.length > MAX_QUERIES

      values.map do |value|
        raise InvalidRequest, "search query must be a string" unless value.is_a?(String)

        query = value.strip
        if query.empty? || query.length > MAX_QUERY_LENGTH || query.match?(/[\u0000-\u001f\u007f]/)
          raise InvalidRequest, "invalid search query"
        end
        query
      end.uniq
    end

    def normalize_urls(values, last_four_user_messages)
      raise InvalidRequest, "URLs must be an array" if values.present? && !values.is_a?(Array)

      values = Array(values)
      raise InvalidRequest, "too many direct URLs" if values.length > MAX_URLS

      user_urls = last_four_user_messages.to_s.scan(%r{https?://[^\s<>"']+}i).filter_map { |url| normalize_url(url) }.to_set
      values.map do |value|
        normalized = normalize_url(value)
        raise InvalidRequest, "invalid direct URL" unless normalized
        raise InvalidRequest, "direct URL was not supplied by the user" unless user_urls.include?(normalized)
        normalized
      end.uniq
    end

    def normalize_url(value)
      return nil unless value.is_a?(String) && value.length <= MAX_URL_LENGTH

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
