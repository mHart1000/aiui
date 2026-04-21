require "test_helper"

class Rag::TextExtractorTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join("test", "fixtures", "files")

  setup do
    FileUtils.mkdir_p(FIXTURES)
    @txt_path = FIXTURES.join("sample.txt")
    File.write(@txt_path, "plain text fixture sentinel SENTINEL123")

    @md_path = FIXTURES.join("sample.md")
    File.write(@md_path, "# Title\n\nMarkdown body SENTINEL456")

    @json_path = FIXTURES.join("sample.json")
    File.write(@json_path, %({"key":"SENTINEL789"}))
  end

  test "extracts txt files" do
    doc = RagDocument.new(file_format: "txt")
    text = Rag::TextExtractor.call(doc, path: @txt_path.to_s)
    assert_includes text, "SENTINEL123"
  end

  test "extracts md files" do
    doc = RagDocument.new(file_format: "md")
    text = Rag::TextExtractor.call(doc, path: @md_path.to_s)
    assert_includes text, "SENTINEL456"
  end

  test "extracts json files verbatim" do
    doc = RagDocument.new(file_format: "json")
    text = Rag::TextExtractor.call(doc, path: @json_path.to_s)
    assert_includes text, "SENTINEL789"
  end

  test "raises on empty extraction" do
    empty_path = FIXTURES.join("empty.txt")
    File.write(empty_path, "")
    doc = RagDocument.new(file_format: "txt")
    assert_raises(RuntimeError) do
      Rag::TextExtractor.call(doc, path: empty_path.to_s)
    end
  ensure
    File.delete(empty_path) if File.exist?(empty_path)
  end

  test "raises on unsupported format" do
    doc = RagDocument.new(file_format: "xlsx")
    assert_raises(RuntimeError) do
      Rag::TextExtractor.call(doc, path: @txt_path.to_s)
    end
  end
end
