require "json"
require "uri"

module WebResearch
  class AuditLog
    EXCERPT_CHARS = 1_000

    class << self
      def info(event, **attributes)
        write(:info, event, attributes)
      end

      def warn(event, **attributes)
        write(:warn, event, attributes)
      end

      def safe_url(url)
        uri = URI.parse(url.to_s)
        uri.user = nil
        uri.password = nil
        uri.query = nil
        uri.fragment = nil
        uri.to_s
      rescue URI::InvalidURIError
        "[invalid URL]"
      end

      def excerpt(text, limit: EXCERPT_CHARS)
        normalized = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").gsub(/\s+/, " ").strip
        return normalized unless limit
        return normalized if normalized.length <= limit

        "#{normalized[0, limit]}…"
      end

      private

      def write(level, event, attributes)
        safe_attributes = attributes.transform_values do |value|
          value.is_a?(String) ? value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "") : value
        end
        Rails.logger.public_send(level, "WEBRESEARCH EVENT=#{event} data=#{JSON.generate(safe_attributes)}")
      end
    end
  end
end
