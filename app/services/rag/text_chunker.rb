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

    def overlap_tail(chunk)
      return "" if @overlap <= 0 || chunk.length <= @overlap
      chunk[-@overlap..]
    end

    def hard_split(long_text)
      step = @target - @overlap
      step = @target if step <= 0
      pieces = []
      i = 0
      while i < long_text.length
        pieces << long_text[i, @target]
        i += step
      end
      pieces
    end
  end
end
