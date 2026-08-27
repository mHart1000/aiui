# frozen_string_literal: true

# Stateful port of the streaming sentence chunker in
# aiui-client/src/composables/useTtsPlayer.js (extractCompleteSentences and
# friends). Feed LLM text chunks in, get back sentences normalized for TTS.
# Unlike the browser path, fenced code blocks are dropped, tracked across feeds.
class SentenceChunker
  def initialize
    @buffer = +""
    @in_fence = false
    @fence_carry = +""
  end

  # Returns the sentences completed by this chunk, markdown-stripped.
  def feed(text)
    append_outside_fences(text)
    extract_complete_sentences.filter_map { |sentence| spoken(sentence) }
  end

  # Emits the leftover buffer as one final sentence, or nil (port of flushBuffer).
  def flush
    @buffer << @fence_carry unless @in_fence
    @fence_carry = +""
    remainder = @buffer
    @buffer = +""
    return nil if remainder.strip.empty? || code_or_url?(remainder)
    spoken(remainder.strip)
  end

  private

  # Buffers text, swallowing anything inside ``` fences. A marker can split
  # across feeds, so up to two trailing backticks are carried to the next one.
  def append_outside_fences(text)
    data = @fence_carry + text
    @fence_carry = +""
    kept = +""
    pos = 0
    while (idx = data.index("```", pos))
      kept << data[pos...idx] unless @in_fence
      @in_fence = !@in_fence
      pos = idx + 3
    end
    tail = data[pos..] || ""
    if (partial = tail[/`{1,2}\z/])
      @fence_carry = partial
      tail = tail[0...-partial.length]
    end
    kept << tail unless @in_fence
    @buffer << kept
  end

  def extract_complete_sentences
    sentences = []

    # Pass 1: complete lines (possible bullets); a trailing partial line stays buffered
    lines = @buffer.split("\n", -1)
    ends_with_newline = @buffer.end_with?("\n")
    buffer_lines = ends_with_newline ? lines : lines[0...-1]
    @buffer = ends_with_newline ? +"" : +(lines.last || "")

    buffer_lines.each do |line|
      trimmed = line.strip
      next if trimmed.empty?

      bullet = trimmed.match?(/\A[*•-]\s+/) || trimmed.match?(/\A\d+\.\s+/)
      if bullet && !code_or_url?(trimmed) && trimmed.length > 5
        sentences << trimmed
      else
        sentences.concat(split_by_sentence_punctuation(trimmed))
      end
    end

    # Pass 2: complete sentences in the partial line; the rest stays buffered
    last_end = 0
    @buffer.scan(/[^.!?]+[.!?]+/) do
      sentence = Regexp.last_match[0].strip
      sentences << sentence if !sentence.empty? && !code_or_url?(sentence)
      last_end = Regexp.last_match.end(0)
    end
    @buffer = +(@buffer[last_end..] || "")

    sentences
  end

  def split_by_sentence_punctuation(text)
    sentences = []
    last_end = 0
    text.scan(/[^.!?]+[.!?]+/) do
      sentences << Regexp.last_match[0].strip
      last_end = Regexp.last_match.end(0)
    end
    remainder = (text[last_end..] || "").strip
    sentences << remainder unless remainder.empty?
    sentences
  end

  # URLs and mostly-non-alphabetic text (likely code) are not spoken
  def code_or_url?(text)
    return true if text.match?(%r{\Ahttps?://})
    text.count("a-zA-Z") < text.length * 0.3
  end

  def spoken(sentence)
    result = strip_markdown(sentence.strip)
    result.empty? ? nil : result
  end

  # Markdown -> speakable plain text; same replacement chain and order as the browser
  def strip_markdown(text)
    text
      .gsub(/!\[([^\]]*)\]\([^)]*\)/, '\1')  # images -> alt text
      .gsub(/\[([^\]]+)\]\([^)]*\)/, '\1')   # links -> link text
      .gsub(/`([^`]+)`/, '\1')               # inline code -> spoken content
      .gsub(/\*{1,3}([^*]+)\*{1,3}/, '\1')   # bold/italic -> inner text
      .gsub(/~~([^~]+)~~/, '\1')             # strikethrough -> inner text
      .gsub(/^\s{0,3}\#{1,6}\s+/, "")        # heading markers
      .gsub(/^\s{0,3}>\s?/, "")              # blockquote markers
      .gsub(/^\s{0,3}[-*+•]\s+/, "")         # list markers
      .gsub(/[`*]/, "")                      # stray backticks/asterisks
      .gsub(/\s*(?:—|--)\s*/, ". ")          # em dash / double hyphen -> pause
      .gsub(/\s+–\s+/, ". ")                 # spaced en dash -> pause (keep 10–20 ranges)
      .gsub(/\s{2,}/, " ")
      .strip
  end
end
