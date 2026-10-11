require "marcel"
require "pdf/reader"

class PdfAttachmentProcessor
  MAX_BYTES = 8.megabytes
  MAX_PAGES = 100
  MIN_TEXT_CHARS = 1_000
  DEFAULT_TEXT_CHARS = 24_000
  MAX_TEXT_CHARS = 48_000

  Result = Data.define(:filename, :text) do
    def source
      { "filename" => filename, "text" => text }
    end
  end

  class Error < StandardError; end

  def self.call(upload:, max_text_chars: DEFAULT_TEXT_CHARS, content_type: nil)
    new(upload: upload, max_text_chars: max_text_chars).call(content_type: content_type)
  end

  def self.text_limit(value)
    limit = Integer(value)
    return limit if limit.between?(MIN_TEXT_CHARS, MAX_TEXT_CHARS)

    raise Error, "PDF text limit must be between #{MIN_TEXT_CHARS} and #{MAX_TEXT_CHARS} characters."
  rescue ArgumentError, TypeError
    raise Error, "PDF text limit must be a whole number."
  end

  def initialize(upload:, max_text_chars:)
    @upload = upload
    @max_text_chars = Integer(max_text_chars)
  rescue ArgumentError, TypeError
    raise Error, "PDF text limit must be a whole number."
  end

  def call(content_type: nil)
    validate_upload!
    raise Error, "Files must be PDFs." unless (content_type || detected_type) == "application/pdf"

    reader = PDF::Reader.new(@upload.tempfile.path)
    if reader.page_count > MAX_PAGES
      raise Error, "PDFs can contain at most #{MAX_PAGES} pages."
    end

    text = extract_text(reader)
    raise Error, "The PDF does not contain extractable text." if text.blank?

    Result.new(filename: sanitized_filename, text: text)
  rescue PDF::Reader::Error => e
    Rails.logger.warn("PdfAttachmentProcessor: #{e.class}: #{e.message}")
    raise Error, "The PDF could not be read."
  ensure
    @upload.tempfile.rewind if @upload.respond_to?(:tempfile) && @upload.tempfile.respond_to?(:rewind)
  end

  private

  def validate_upload!
    unless @upload.respond_to?(:tempfile) && @upload.tempfile.respond_to?(:path)
      raise Error, "A PDF file is required."
    end
    raise Error, "Each PDF must be #{MAX_BYTES / 1.megabyte} MiB or smaller." if @upload.size > MAX_BYTES
    raise Error, "PDF extraction budget is invalid." unless @max_text_chars.between?(1, MAX_TEXT_CHARS)
  end

  def detected_type
    @upload.tempfile.rewind
    Marcel::MimeType.for(@upload.tempfile)
  ensure
    @upload.tempfile.rewind
  end

  def extract_text(reader)
    text = +""
    reader.pages.each_with_index do |page, index|
      break if text.length >= @max_text_chars

      page_text = page.text.to_s.strip
      next if page_text.blank?

      separator = text.empty? ? "" : "\n\n"
      available = @max_text_chars - text.length - separator.length
      break unless available.positive?

      text << separator << page_text[0, available]
    end
    text
  end

  def sanitized_filename
    raw = (@upload.original_filename.presence || "document.pdf").to_s.tr("\\", "/")
    basename = File.basename(raw)
    stem = File.basename(basename, File.extname(basename)).presence || "document"
    "#{ActiveStorage::Filename.new(stem).sanitized.sub(/\A[.\s-]+/, "").presence || "document"}.pdf"
  end
end
