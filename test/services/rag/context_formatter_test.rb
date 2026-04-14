require "test_helper"

class Rag::ContextFormatterTest < ActiveSupport::TestCase
  FakeDoc = Struct.new(:id, :original_filename, :title)
  FakeChunk = Struct.new(:content, :rag_document)

  test "empty chunks returns nil" do
    assert_nil Rag::ContextFormatter.format([])
    assert_nil Rag::ContextFormatter.format(nil)
  end

  test "formats multiple chunks with source labels" do
    doc_a = FakeDoc.new(1, "notes.md", nil)
    doc_b = FakeDoc.new(2, "report.pdf", nil)
    chunks = [
      FakeChunk.new("first chunk body", doc_a),
      FakeChunk.new("second chunk body", doc_b)
    ]
    output = Rag::ContextFormatter.format(chunks)

    assert_includes output, "[Context from your personal documents]"
    assert_includes output, "--- Source: notes.md ---"
    assert_includes output, "first chunk body"
    assert_includes output, "--- Source: report.pdf ---"
    assert_includes output, "second chunk body"
    assert_includes output, "[/Context]"
  end

  test "falls back to title when filename missing" do
    doc = FakeDoc.new(9, nil, "My Notes")
    output = Rag::ContextFormatter.format([ FakeChunk.new("body", doc) ])
    assert_includes output, "My Notes"
  end

  test "truncates oversized chunks" do
    doc = FakeDoc.new(1, "big.txt", nil)
    big = FakeChunk.new("A" * 5000, doc)
    output = Rag::ContextFormatter.format([ big ])
    assert_includes output, "…"
    refute_includes output, "A" * 3000
  end
end
