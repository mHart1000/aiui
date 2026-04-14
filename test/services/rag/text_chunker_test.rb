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
end
