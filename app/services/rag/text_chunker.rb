module Rag
  class TextChunker
    # 1500 chars ≈ 375–500 tokens for typical English/markdown prose, which
    # stays safely under llama.cpp's default physical batch size of 512.
    # Dense content (code, JSON) tokenises at ~3 chars/token so 1500 chars
    # can reach ~500 tokens — still under the limit with headroom.
    DEFAULT_TARGET_CHARS = 1500
    DEFAULT_OVERLAP_CHARS = 300

    def self.call(text, target_chars: DEFAULT_TARGET_CHARS, overlap_chars: DEFAULT_OVERLAP_CHARS)
      new(text, target_chars, overlap_chars).call
    end

    def initialize(text, target_chars, overlap_chars)
      @text = text.to_s
      @target = target_chars
      @overlap = overlap_chars
    end

    def call
      return [] if @text.strip.empty?

      paragraphs = @text.split(/\n{2,}/).map(&:strip).reject(&:empty?)
      chunks = []
      current = +""

      paragraphs.each do |para|
        # If a single paragraph exceeds the target, hard-split it.
        if para.length > @target
          flush(chunks, current)
          current = +""
          hard_split(para).each { |piece| chunks << piece }
          next
        end

        if current.empty?
          current << para
        elsif current.length + 2 + para.length <= @target
          current << "\n\n" << para
        else
          chunks << current
          current = +overlap_tail(current)
          current << "\n\n" unless current.empty?
          current << para
        end
      end

      flush(chunks, current)
      chunks
    end

    private

    def flush(chunks, current)
      chunks << current unless current.strip.empty?
    end

    # Walks back from the tail of the chunk by @overlap chars, then nudges
    # forward to the next whitespace (up to a small budget) so the overlap
    # starts at a word boundary rather than mid-word. Falls back to the raw
    # position for dense text with no whitespace nearby — better to keep
    # some overlap than lose it entirely.
    def overlap_tail(chunk)
      return "" if @overlap <= 0 || chunk.length <= @overlap
      raw = chunk.length - @overlap
      probe = raw
      limit = [ raw + 30, chunk.length ].min
      while probe < limit && chunk[probe] && !chunk[probe].match?(/\s/)
        probe += 1
      end
      start = (probe < limit && chunk[probe].to_s.match?(/\s/)) ? probe : raw
      chunk[start..].to_s.lstrip
    end

    # Split a single oversized paragraph. Tries, in order:
    #   1. sentence boundary (. ! ?) inside a window near the target length
    #   2. whitespace boundary inside the same window
    #   3. raw character split as a last resort
    # The preferred break point is whichever is closest to @target without
    # going over, so chunks stay close to the target size without ever
    # cutting mid-word when the text has any reasonable structure.
    def hard_split(long_text)
      pieces = []
      remaining = long_text

      while remaining.length > @target
        split_at = find_split_point(remaining, @target)
        piece = remaining[0, split_at].rstrip
        pieces << piece unless piece.empty?

        overlap_start = [ split_at - @overlap, 0 ].max
        overlap_start = advance_to_word_boundary(remaining, overlap_start)
        remaining = remaining[overlap_start..].to_s.lstrip
      end

      pieces << remaining unless remaining.strip.empty?
      pieces
    end

    # Search backward from `target` within a small window for a good place
    # to break. Prefer sentence punctuation over whitespace, whitespace over
    # nothing. Returns the index AFTER the break character so callers can
    # slice [0, split_at] and get a clean chunk.
    def find_split_point(text, target)
      return text.length if text.length <= target

      window_size = [ target / 4, 200 ].min
      window_start = [ target - window_size, 0 ].max
      window = text[window_start, target - window_start]

      if (m = window.rindex(/[.!?](?=\s|\z)/))
        return window_start + m + 1
      end

      if (m = window.rindex(/\s/))
        return window_start + m
      end

      target
    end

    # Same bounded-probe pattern as overlap_tail — nudge forward up to 30
    # chars looking for whitespace, otherwise leave the position alone.
    def advance_to_word_boundary(text, pos)
      return 0 if pos <= 0
      probe = pos
      limit = [ pos + 30, text.length ].min
      while probe < limit && text[probe] && !text[probe].match?(/\s/)
        probe += 1
      end
      (probe < limit && text[probe].to_s.match?(/\s/)) ? probe : pos
    end
  end
end
