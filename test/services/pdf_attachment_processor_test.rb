require "test_helper"
require "tempfile"

class PdfAttachmentProcessorTest < ActiveSupport::TestCase
  def uploaded_file(bytes, filename: "document.pdf", type: "application/pdf")
    tempfile = Tempfile.new([ "pdf-upload", ".pdf" ], binmode: true)
    tempfile.write(bytes)
    tempfile.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: filename, type: type)
  end

  def simple_pdf(text)
    stream = "BT\n/F1 12 Tf\n72 720 Td\n(#{text.gsub(/([()\\])/, '\\\\1')}) Tj\nET\n"
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream"
    ]
    pdf = +"%PDF-1.4\n"
    offsets = objects.map.with_index(1) do |object, index|
      offset = pdf.bytesize
      pdf << "#{index} 0 obj\n#{object}\nendobj\n"
      offset
    end
    xref_offset = pdf.bytesize
    pdf << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
    offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{xref_offset}\n%%EOF\n"
    pdf
  end

  test "extracts text based on PDF bytes rather than the declared MIME type" do
    upload = uploaded_file(simple_pdf("Read this report"), filename: "../report.pdf", type: "image/png")
    result = PdfAttachmentProcessor.call(upload: upload, max_text_chars: 1_000)

    assert_equal "report.pdf", result.filename
    assert_includes result.text, "Read this report"
  ensure
    upload&.tempfile&.close!
  end

  test "caps extracted text at the requested user limit" do
    upload = uploaded_file(simple_pdf("x" * 2_000))
    result = PdfAttachmentProcessor.call(upload: upload, max_text_chars: 1_000)

    assert_equal 1_000, result.text.length
  ensure
    upload&.tempfile&.close!
  end

  test "rejects PDFs without extractable text" do
    upload = uploaded_file(simple_pdf(""))

    error = assert_raises(PdfAttachmentProcessor::Error) { PdfAttachmentProcessor.call(upload: upload) }
    assert_match(/does not contain extractable text/, error.message)
  ensure
    upload&.tempfile&.close!
  end

  test "rejects non-PDF bytes even when declared as a PDF" do
    upload = uploaded_file("not a PDF")

    error = assert_raises(PdfAttachmentProcessor::Error) { PdfAttachmentProcessor.call(upload: upload) }
    assert_match(/must be PDFs/, error.message)
  ensure
    upload&.tempfile&.close!
  end
end
