require "test_helper"

class Rag::TextChunkerTest < ActiveSupport::TestCase
  test "empty input produces empty array" do
    assert_equal [], Rag::TextChunker.call("")
    assert_equal [], Rag::TextChunker.call("   \n\n   ")
  end

  test "short text fits in a single chunk" do
    chunks = Rag::TextChunker.call("one paragraph of text", target_chars: 2000)
    assert_equal 1, chunks.length
    assert_equal "one paragraph of text", chunks.first
  end

  test "multiple paragraphs under target become one chunk" do
    text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
    chunks = Rag::TextChunker.call(text, target_chars: 2000)
    assert_equal 1, chunks.length
    assert_includes chunks.first, "First paragraph."
    assert_includes chunks.first, "Third paragraph."
  end

  test "splits into multiple chunks when content exceeds target" do
    paragraphs = (1..10).map { |i| "Paragraph #{i} " + ("x" * 200) }
    text = paragraphs.join("\n\n")
    chunks = Rag::TextChunker.call(text, target_chars: 500, overlap_chars: 100)
    assert_operator chunks.length, :>, 1
    chunks.each { |c| assert_operator c.length, :<=, 600 }
  end

  test "adjacent chunks share overlap content" do
    paragraphs = (1..8).map { |i| "PARA#{i}" + ("y" * 180) }
    text = paragraphs.join("\n\n")
    chunks = Rag::TextChunker.call(text, target_chars: 400, overlap_chars: 100)
    assert_operator chunks.length, :>=, 2
    tail = chunks[0][-50..]
    assert_includes chunks[1], tail[0, 20]
  end

  test "single paragraph longer than target is hard split" do
    long = "z" * 5000
    chunks = Rag::TextChunker.call(long, target_chars: 1000, overlap_chars: 200)
    assert_operator chunks.length, :>=, 5
    chunks.each { |c| assert_operator c.length, :<=, 1000 }
  end

  test "hard split prefers sentence boundaries when available" do
    sentences = (1..20).map { |i| "This is sentence number #{i} with some extra words to pad it out." }
    long_paragraph = sentences.join(" ")
    chunks = Rag::TextChunker.call(long_paragraph, target_chars: 400, overlap_chars: 80)

    assert_operator chunks.length, :>=, 2
    # Each split point should be after a period — so no chunk starts with a
    # lowercase continuation word and none ends mid-sentence (bar the last).
    chunks[0..-2].each do |c|
      assert_match(/[.!?]\s*\z/, c.strip, "chunk did not end on sentence boundary: #{c.inspect}")
    end
  end

  test "hard split does not cut words in half when whitespace is available" do
    words = (1..300).map { |i| "supercalifragilistic#{i}" }
    long = words.join(" ")
    chunks = Rag::TextChunker.call(long, target_chars: 500, overlap_chars: 100)

    assert_operator chunks.length, :>=, 2
    # Every chunk (except possibly the last) should end on a whole word.
    chunks[0..-2].each do |c|
      stripped = c.rstrip
      last_word = stripped.split(/\s+/).last
      assert_match(/\Asupercalifragilistic\d+\z/, last_word,
        "chunk ended mid-word: #{stripped[-40..].inspect}")
    end
  end

  test "preserves critical term that previously straddled a hard split" do
    # Regression guard: "eRecord, access control..." got cut into ", access
    # control..." because hard_split sliced on char index. After the fix, the
    # term should survive intact in at least one chunk.
    filler_before = "Lorem ipsum dolor sit amet consectetur adipiscing elit. " * 20
    filler_after = "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. " * 20
    text = "#{filler_before}eRecord, access control, billing, and interoperability matter here. #{filler_after}"
    chunks = Rag::TextChunker.call(text, target_chars: 800, overlap_chars: 150)

    assert chunks.any? { |c| c.include?("eRecord, access control") },
      "expected at least one chunk to contain the intact phrase; got chunk previews: " +
      chunks.map { |c| c[0, 80].inspect }.join(", ")
  end
end
