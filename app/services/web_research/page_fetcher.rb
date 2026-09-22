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
    MAX_PASSAGE_LENGTH = 1_200
    MAX_QUERY_TERMS = 24
    MIN_SUBSTANTIVE_TEXT_LENGTH = 200
    TEXT_BLOCK_ELEMENTS = %w[
      address article blockquote br caption dd details div dl dt figure figcaption h1 h2 h3 h4 h5 h6
      hr li main ol p pre section summary table tbody td tfoot th thead tr ul
    ].freeze
    ALLOWED_CONTENT_TYPES = %w[text/html application/xhtml+xml text/plain].freeze
    QUERY_STOP_WORDS = %w[
      an and are as at be by do for from go he how if in into is it latest me my no of on or so
      that the this to up us we what when where which who why with
    ].freeze
    OMISSION_MARKER = "[Non-contiguous page text omitted]".freeze

    FetchResult = Struct.new(:text, :truncated, :blocks, :query, :full_length, keyword_init: true) do
      def extraction_status
        return "thin" if text.length < PageFetcher::MIN_SUBSTANTIVE_TEXT_LENGTH

        truncated ? "bounded" : "full"
      end
    end

    class Error < StandardError; end
    class UnsafeTarget < Error; end

    def self.render_extract(blocks, query, full_length, limit)
      new.render_extract(blocks, query, full_length, limit)
    end

    def render_extract(blocks, query, full_length, limit)
      selected = full_length > limit ? relevant_blocks(blocks, query, limit) : blocks
      render_bounded(selected, limit)
    end

    def fetch(url, deadline: monotonic_now + 20, query: nil)
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
        return extract_text(body, type, query: query)
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
      response = Timeout.timeout(remaining_seconds(deadline), Error, "research deadline exceeded") do
        http.request(request) do |res|
          encoding = res["content-encoding"]
          raise Error, "unsupported content encoding" if encoding.present? && encoding != "identity"
          res.read_body do |chunk|
            body << chunk
            raise Error, "response body was too large" if body.bytesize > MAX_BODY_BYTES
            raise Error, "research deadline exceeded" if monotonic_now >= deadline
          end
        end
      end
      AuditLog.info("http_response", url: AuditLog.safe_url(uri.to_s), status: response.code.to_i,
        content_type: response.content_type.to_s.downcase, body_bytes: body.bytesize)
      [ response, body ]
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError, EOFError, IOError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT => e
      raise Error, e.message
    end

    def extract_text(body, content_type, query: nil)
      blocks =
        if content_type == "text/plain"
          plain_text_blocks(body)
        else
          html_text_blocks(body)
        end
      raise Error, "page had no readable text" if blocks.empty?

      blocks = blocks.flat_map { |block| split_long_block(block) }
      full_length = blocks.sum(&:length) + ([ blocks.length - 1, 0 ].max * 2)
      truncated = full_length > MAX_TEXT_LENGTH
      selected = truncated ? relevant_blocks(blocks, query, MAX_TEXT_LENGTH) : blocks
      FetchResult.new(text: render_bounded(selected, MAX_TEXT_LENGTH), truncated: truncated,
        blocks: blocks, query: query, full_length: full_length)
    end

    def plain_text_blocks(body)
      text = body.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      text.split(/\n\s*\n+/).filter_map { |block| normalize_text(block).presence }
    end

    def html_text_blocks(body)
      document = Nokogiri::HTML5.parse(body)
      document.css("script, style, form, iframe, object, embed, nav, header, footer, aside, noscript").remove
      body_root = document.at_css("body") || document
      body_blocks = blocks_from_root(body_root)
      semantic_root = document.css('article, main, [role="main"]').max_by { |node| normalize_text(node.text).length }
      return body_blocks unless semantic_root

      semantic_blocks = blocks_from_root(semantic_root)
      return body_blocks if blocks_length(semantic_blocks) < MIN_SUBSTANTIVE_TEXT_LENGTH && blocks_length(body_blocks) > blocks_length(semantic_blocks)

      semantic_blocks
    end

    def blocks_from_root(root)
      blocks = []
      buffer = +""
      append_html_blocks(root, blocks, buffer)
      flush_text_block(blocks, buffer)
      blocks.uniq
    end

    def append_html_blocks(node, blocks, buffer)
      if node.text?
        buffer << node.text
        return
      end
      return unless node.element? || node.document?

      boundary = TEXT_BLOCK_ELEMENTS.include?(node.name)
      flush_text_block(blocks, buffer) if boundary
      case node.name
      when "table"
        blocks.concat(table_blocks(node))
      when "dl"
        blocks.concat(definition_blocks(node))
      else
        node.children.each { |child| append_html_blocks(child, blocks, buffer) }
      end
      flush_text_block(blocks, buffer) if boundary
    end

    def flush_text_block(blocks, buffer)
      text = normalize_text(buffer)
      blocks << text if text.present?
      buffer.clear
    end

    def table_blocks(table)
      blocks = table.xpath("./caption").flat_map { |caption| blocks_from_root(caption) }
      rows = table.xpath("./tr | ./thead/tr | ./tbody/tr | ./tfoot/tr")
      simple_columns = rows.all? do |row|
        row.xpath("./th | ./td").all? do |cell|
          %w[colspan rowspan].all? { |attribute| cell[attribute].nil? || cell[attribute] == "1" }
        end
      end
      headers = []
      rows.each do |row|
        cells = row.xpath("./th | ./td")
        next if cells.empty?

        values = cells.map { |cell| blocks_from_root(cell).join(" ") }
        next if values.all?(&:blank?)

        if cells.all? { |cell| cell.name == "th" }
          headers = values
        elsif simple_columns && headers.length == values.length
          values = values.each_with_index.map do |value, index|
            headers[index].present? ? "#{headers[index]}: #{value}" : value
          end
        end
        blocks << values.join(" | ")
      end
      blocks
    end

    def definition_blocks(list)
      blocks = []
      terms = []
      described = false
      list.children.each do |node|
        case node.name
        when "dt"
          terms = [] if described
          described = false
          term = blocks_from_root(node).join(" ")
          terms << term if term.present?
        when "dd"
          descriptions = blocks_from_root(node)
          next if descriptions.empty?

          descriptions.each { |text| blocks << [ terms.join(" / "), text ].reject(&:blank?).join(": ") }
          described = true
        else
          text_blocks = node.name == "div" ? definition_blocks(node) : blocks_from_root(node)
          next if text_blocks.empty?

          blocks << terms.join(" / ") if terms.any? && !described
          terms = []
          described = false
          blocks.concat(text_blocks)
        end
      end
      blocks << terms.join(" / ") if terms.any? && !described
      blocks
    end

    def blocks_length(blocks)
      blocks.sum(&:length) + ([ blocks.length - 1, 0 ].max * 2)
    end

    def normalize_text(text)
      text.to_s.gsub(/\s+/, " ").strip
    end

    def split_long_block(text)
      return [ text ] if text.length <= MAX_PASSAGE_LENGTH

      chunks = []
      remaining = text
      while remaining.length > MAX_PASSAGE_LENGTH
        window = remaining[0, MAX_PASSAGE_LENGTH + 1]
        boundary = window.rindex(/(?<=[.!?])\s/) || window.rindex(/\s/)
        boundary = MAX_PASSAGE_LENGTH if boundary.nil? || boundary < MAX_PASSAGE_LENGTH / 2
        chunks << remaining.slice!(0, boundary).strip
        remaining = remaining.lstrip
      end
      chunks << remaining if remaining.present?
      chunks
    end

    def relevant_blocks(blocks, query, limit)
      terms = query_terms(query)
      return blocks if terms.empty?

      normalized_blocks = blocks.map(&:downcase)
      frequencies = terms.to_h do |term|
        [ term, normalized_blocks.count { |text| term_present?(text, term) } ]
      end
      ranked = blocks.each_index.filter_map do |index|
        matches = terms.select { |term| term_present?(normalized_blocks[index], term) }
        next if matches.empty?

        discrimination = matches.sum do |term|
          inverse_frequency = Math.log((blocks.length + 1).to_f / (frequencies[term] + 1)) + 1
          inverse_frequency * [ term.length, 8 ].min
        end
        coverage = matches.length.to_f / terms.length
        score = discrimination + (coverage * 10)
        [ score, index ] if score.positive?
      end.sort_by { |score, index| [ -score, index ] }
      return blocks if ranked.empty?

      selected = {}
      ranked.each do |_score, index|
        [ index, index - 1, index + 1 ].each do |candidate|
          next unless candidate.between?(0, blocks.length - 1)
          next if selected.key?(candidate)

          projected_indices = (selected.keys + [ candidate ]).sort
          next if blocks_length(mark_omissions(projected_indices, blocks)) > limit

          selected[candidate] = true
        end
      end
      mark_omissions(selected.keys.sort, blocks)
    end

    def query_terms(query)
      terms = query.to_s.downcase.scan(/[[:alnum:]]{2,}/).uniq.reject { |term| QUERY_STOP_WORDS.include?(term) }
      return terms if terms.length <= MAX_QUERY_TERMS

      (terms.first(MAX_QUERY_TERMS / 2) + terms.last(MAX_QUERY_TERMS / 2)).uniq
    end

    def term_present?(text, term)
      text.match?(/(?<![[:alnum:]])#{Regexp.escape(term)}(?![[:alnum:]])/)
    end

    def mark_omissions(indices, blocks)
      marked = []
      previous = nil
      marked << OMISSION_MARKER if indices.first&.positive?
      indices.each do |index|
        marked << OMISSION_MARKER if previous && index > previous + 1
        marked << blocks[index]
        previous = index
      end
      marked << OMISSION_MARKER if indices.last && indices.last < blocks.length - 1
      marked
    end

    def render_bounded(blocks, limit)
      output = +""
      blocks.each do |block|
        separator = output.empty? ? "" : "\n\n"
        remaining = limit - output.length - separator.length
        break if remaining <= 0

        output << separator
        if block.length <= remaining
          output << block
        else
          clipped = truncate_at_boundary(block, remaining, require_sentence: output.present?)
          if clipped.empty?
            output.delete_suffix!(separator)
          else
            output << clipped
          end
          break
        end
      end
      output
    end

    def truncate_at_boundary(text, limit, require_sentence: false)
      return "" if limit <= 0

      slice = text[0, limit]
      minimum = (limit * 0.6).floor
      boundary = slice.rindex(/(?<=[.!?])\s/)
      return "" if require_sentence && (boundary.nil? || boundary < minimum)

      boundary = slice.rindex(/\s/) if boundary.nil? || boundary < minimum
      clipped = boundary && boundary >= minimum ? slice[0, boundary] : slice
      return clipped if clipped.length >= text.length

      clipped = clipped.rstrip
      clipped = clipped[0, limit - 1].rstrip if clipped.length >= limit
      "#{clipped}…"
    end

    def remaining_seconds(deadline)
      remaining = deadline - monotonic_now
      raise Error, "research deadline exceeded" unless remaining.positive?

      remaining
    end

    def self.monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def monotonic_now
      self.class.monotonic_now
    end
  end
end
