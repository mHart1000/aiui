module Rag
  class ContextFormatter
    # Default-level values; per-request caps are chosen by the web search level.
    HARD_CAP_CHARS = WebResearch::Profile.for_level(WebResearch::Profile::DEFAULT_LEVEL)[:rag_hard_cap_chars]
    PER_CHUNK_CAP_CHARS = WebResearch::Profile.for_level(WebResearch::Profile::DEFAULT_LEVEL)[:rag_per_chunk_cap_chars]

    def self.format(chunks, budgets: nil)
      return nil if chunks.blank?

      b = budgets || {}
      hard_cap = b[:rag_hard_cap_chars] || HARD_CAP_CHARS
      per_chunk_cap = b[:rag_per_chunk_cap_chars] || PER_CHUNK_CAP_CHARS

      parts = [ "[Context from your personal documents]" ]
      total = parts.first.length

      chunks.each do |chunk|
        label = "--- Source: #{source_label(chunk)} ---"
        body = truncate(chunk.content.to_s, per_chunk_cap)
        piece = "\n\n#{label}\n#{body}"

        break if total + piece.length > hard_cap
        parts << piece
        total += piece.length
      end

      parts << "\n\n[/Context]"
      parts.join
    end

    def self.source_label(chunk)
      doc = chunk.rag_document
      doc&.original_filename.presence || doc&.title.presence || "document ##{doc&.id || '?'}"
    end

    def self.truncate(text, limit)
      return text if text.length <= limit
      "#{text[0, limit]}…"
    end
  end
end
