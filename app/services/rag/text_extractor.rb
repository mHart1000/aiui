require "pdf/reader"
require "docx"

module Rag
  class TextExtractor
    def self.call(rag_document, path:)
      new(rag_document, path).call
    end

    def initialize(rag_document, path)
      @document = rag_document
      @path = path
    end

    def call
      text = extract
      raise "Extraction produced empty text" if text.nil? || text.strip.empty?
      text
    end

    private

    def extract
      case @document.file_format
      when "pdf"
        PDF::Reader.new(@path).pages.map(&:text).join("\n\n")
      when "docx"
        Docx::Document.open(@path).paragraphs.map(&:text).reject(&:empty?).join("\n\n")
      when "txt", "md", "json"
        File.read(@path)
      else
        raise "Unsupported file format: #{@document.file_format.inspect}"
      end
    end
  end
end
