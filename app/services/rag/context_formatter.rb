module Rag
  class ContextFormatter
    HARD_CAP_CHARS = 8000
    PER_CHUNK_CAP_CHARS = 1500

    def self.format(chunks)
      return nil if chunks.blank?

      parts = [ "[Context from your personal documents]" ]
      total = parts.first.length

      chunks.each do |chunk|
        label = "--- Source: #{source_label(chunk)} ---"
        body = truncate(chunk.content.to_s, PER_CHUNK_CAP_CHARS)
        piece = "\n\n#{label}\n#{body}"

        break if total + piece.length > HARD_CAP_CHARS
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
