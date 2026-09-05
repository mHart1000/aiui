require "ipaddr"
require "net/http"
require "nokogiri"
require "resolv"
require "socket"
require "timeout"
require "uri"

module WebResearch
  class PageFetcher
    MAX_REDIRECTS = 3
    MAX_BODY_BYTES = 1_048_576
    MAX_TEXT_LENGTH = 6_000
    ALLOWED_CONTENT_TYPES = %w[text/html application/xhtml+xml text/plain].freeze

    class Error < StandardError; end
    class UnsafeTarget < Error; end

    def fetch(url, deadline: monotonic_now + 20)
      current = url
      (MAX_REDIRECTS + 1).times do
        raise Error, "research deadline exceeded" if monotonic_now >= deadline
        uri, address = validate_target!(current, deadline: deadline)
        response, body = request(uri, address, deadline)
        if response.is_a?(Net::HTTPRedirection)
          location = response["location"]
          raise Error, "redirect missing location" if location.blank?
          redirected = URI.join(uri, location).to_s
          AuditLog.info("redirect_followed", from: AuditLog.safe_url(current), to: AuditLog.safe_url(redirected), status: response.code.to_i)
          current = redirected
          next
        end
        raise Error, "source returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        type = response.content_type.to_s.downcase
        raise Error, "unsupported content type" unless ALLOWED_CONTENT_TYPES.include?(type)
        return extract_text(body, type)
      end
      raise Error, "too many redirects"
    rescue URI::InvalidURIError, Net::HTTPBadResponse, Net::ProtocolError => e
      raise Error, "invalid HTTP response: #{e.message}"
    end

    private

    public

    def validate_target!(url, deadline: monotonic_now + 20)
      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? && [ 80, 443 ].include?(uri.port)
        raise UnsafeTarget, "unsafe URL"
      end

      addresses = Timeout.timeout(remaining_seconds(deadline)) { Resolv.getaddresses(uri.host) }
      raise Error, "hostname did not resolve" if addresses.empty?
      parsed = addresses.map { |address| IPAddr.new(address) }
      raise UnsafeTarget, "hostname resolved to a non-public address" unless parsed.all? { |address| public_address?(address) }
      [ uri, addresses.first ]
    rescue URI::InvalidURIError, IPAddr::InvalidAddressError
      raise UnsafeTarget, "invalid URL"
    rescue Timeout::Error
      raise Error, "DNS lookup timed out"
    end

    private

    def public_address?(address)
      return false if address.ipv4_mapped?
      return false unless address.ipv4? || address.ipv6?

      if address.ipv4?
        blocked = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.31.196.0/24 192.52.193.0/24 192.88.99.0/24 192.168.0.0/16 192.175.48.0/24 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4]
      else
        return false unless IPAddr.new("2000::/3").include?(address)

        blocked = %w[64:ff9b::/96 64:ff9b:1::/48 2001::/23 2001:db8::/32 2002::/16 3fff::/20 5f00::/16]
      end
      blocked.none? { |range| IPAddr.new(range).include?(address) }
    end

    def request(uri, address, deadline)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.ipaddr = address
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = [ 3, remaining_seconds(deadline) ].min
      http.read_timeout = [ 5, remaining_seconds(deadline) ].min

      request = Net::HTTP::Get.new(uri.request_uri)
      request["Host"] = uri.host
      request["Accept-Encoding"] = "identity"
      body = +""
      response = http.request(request) do |res|
        encoding = res["content-encoding"]
        raise Error, "unsupported content encoding" if encoding.present? && encoding != "identity"
        res.read_body do |chunk|
          body << chunk
          raise Error, "response body was too large" if body.bytesize > MAX_BODY_BYTES
          raise Error, "research deadline exceeded" if monotonic_now >= deadline
        end
      end
      AuditLog.info("http_response", url: AuditLog.safe_url(uri.to_s), status: response.code.to_i,
        content_type: response.content_type.to_s.downcase, body_bytes: body.bytesize)
      [ response, body ]
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError, EOFError, IOError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT => e
      raise Error, e.message
    end

    def extract_text(body, content_type)
      return body.encode("UTF-8", invalid: :replace, undef: :replace, replace: "") [0, MAX_TEXT_LENGTH] if content_type == "text/plain"

      document = Nokogiri::HTML5.parse(body)
      document.css("script, style, form, iframe, object, embed, nav, header, footer, aside, noscript").remove
      text = document.text.gsub(/\s+/, " ").strip
      raise Error, "page had no readable text" if text.empty?
      text[0, MAX_TEXT_LENGTH]
    end

    def remaining_seconds(deadline)
      [ deadline - monotonic_now, 0.1 ].max
    end

    def self.monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def monotonic_now
      self.class.monotonic_now
    end
  end
end
