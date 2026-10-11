require "marcel"

class MessageAttachmentProcessor
  Result = Data.define(:image, :pdf_source)

  def self.call(upload:, max_pdf_text_chars:)
    unless upload.respond_to?(:tempfile) && upload.tempfile.respond_to?(:path)
      raise ImageAttachmentProcessor::Error, "An attachment file is required."
    end

    content_type = detected_type(upload)

    if ImageAttachmentProcessor::ACCEPTED_TYPES.include?(content_type)
      Result.new(image: ImageAttachmentProcessor.call(upload: upload, content_type: content_type), pdf_source: nil)
    elsif content_type == "application/pdf"
      if max_pdf_text_chars <= 0
        raise PdfAttachmentProcessor::Error, "The combined PDF text exceeds the selected limit."
      end

      Result.new(image: nil, pdf_source: PdfAttachmentProcessor.call(upload: upload, max_text_chars: max_pdf_text_chars, content_type: content_type))
    else
      raise ImageAttachmentProcessor::Error, "Files must be JPEG, PNG, WebP, or PDF."
    end
  end

  def self.detected_type(upload)
    upload.tempfile.rewind
    Marcel::MimeType.for(upload.tempfile)
  ensure
    upload.tempfile.rewind
  end
end
