require "image_processing/vips"
require "marcel"
require "tempfile"

class ImageAttachmentProcessor
  MAX_IMAGES = 4
  MAX_BYTES = 10.megabytes
  MAX_EDGE = 2048
  MAX_SOURCE_PIXELS = 100_000_000
  ACCEPTED_TYPES = %w[image/jpeg image/png image/webp].freeze

  Result = Data.define(:tempfile, :filename, :content_type, :width, :height, :original_filename) do
    def attachable
      {
        io: tempfile,
        filename: filename,
        content_type: content_type,
        metadata: {
          width: width,
          height: height,
          original_filename: original_filename
        },
        identify: false
      }
    end

    def close!
      tempfile.close!
    end
  end

  class Error < StandardError
    attr_reader :code, :status

    def initialize(code, message, status: :unprocessable_content)
      @code = code
      @status = status
      super(message)
    end
  end

  def self.call(uploads)
    new(uploads).call
  end

  def initialize(uploads)
    @uploads = Array(uploads).compact
  end

  def call
    raise Error.new("too_many_images", "A message may contain at most four images.") if @uploads.length > MAX_IMAGES

    processed = []
    @uploads.each { |upload| processed << process(upload) }
    processed
  rescue
    processed&.each(&:close!)
    raise
  end

  private

  def process(upload)
    validate_upload!(upload)
    source_type = detected_type(upload)
    unless ACCEPTED_TYPES.include?(source_type)
      if source_type == "application/octet-stream" || ACCEPTED_TYPES.include?(upload.content_type)
        raise Error.new("invalid_image", "The image could not be decoded or normalized.")
      end
      raise Error.new("unsupported_image_type", "Images must be JPEG, PNG, or WebP.")
    end

    source = Vips::Image.new_from_file(upload.tempfile.path, access: :sequential)
    if source.width * source.height > MAX_SOURCE_PIXELS
      raise Error.new("invalid_image", "The image dimensions are too large to process safely.")
    end

    output_type = normalized_type(source_type, source)
    extension = output_type == "image/png" ? "png" : "jpg"
    pipeline = ImageProcessing::Vips
      .source(upload.tempfile)
      .autorot
      .resize_to_limit(MAX_EDGE, MAX_EDGE)
      .convert(extension)
      .saver(**saver_options(output_type))

    tempfile = pipeline.call
    if tempfile.size > MAX_BYTES
      tempfile.close!
      raise Error.new("image_too_large", "The normalized image exceeds 10 MiB.")
    end

    normalized = Vips::Image.new_from_file(tempfile.path, access: :sequential)
    Result.new(
      tempfile: tempfile,
      filename: normalized_filename(upload.original_filename, extension),
      content_type: output_type,
      width: normalized.width,
      height: normalized.height,
      original_filename: sanitized_filename(upload.original_filename)
    )
  rescue Error
    raise
  rescue => e
    Rails.logger.warn("Image normalization failed: #{e.class}: #{e.message}")
    raise Error.new("invalid_image", "The image could not be decoded or normalized.")
  ensure
    upload.tempfile.rewind if upload.respond_to?(:tempfile) && upload.tempfile.respond_to?(:rewind)
  end

  def validate_upload!(upload)
    unless upload.respond_to?(:tempfile) && upload.tempfile.respond_to?(:path)
      raise Error.new("invalid_image", "The image upload is invalid.")
    end
    raise Error.new("image_too_large", "Each image must be 10 MiB or smaller.") if upload.size > MAX_BYTES
  end

  def detected_type(upload)
    upload.tempfile.rewind
    Marcel::MimeType.for(upload.tempfile)
  ensure
    upload.tempfile.rewind
  end

  def normalized_type(source_type, source)
    return source_type if source_type != "image/webp"
    source.has_alpha? ? "image/png" : "image/jpeg"
  end

  def saver_options(content_type)
    return { strip: true, Q: 90 } if content_type == "image/jpeg"
    { strip: true }
  end

  def normalized_filename(original_filename, extension)
    original = sanitized_filename(original_filename)
    stem = File.basename(original, File.extname(original)).presence || "image"
    "#{stem}.#{extension}"
  end

  def sanitized_filename(filename)
    ActiveStorage::Filename.new(filename.presence || "image").sanitized
  end
end
