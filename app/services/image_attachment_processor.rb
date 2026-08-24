require "image_processing/vips"
require "marcel"

class ImageAttachmentProcessor
  MAX_IMAGES = 4
  MAX_BYTES = 8.megabytes
  MAX_SOURCE_PIXELS = 100_000_000
  ACCEPTED_TYPES = %w[image/jpeg image/png image/webp].freeze
  EXTENSIONS = {
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/webp" => "webp"
  }.freeze

  Result = Data.define(:tempfile, :filename, :content_type, :width, :height, :original_filename) do
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

  def self.call(upload:, max_pixels:)
    new(upload: upload, max_pixels: max_pixels).call
  end

  def initialize(upload:, max_pixels:)
    @upload = upload
    @max_pixels = max_pixels
  end

  def call
    validate_upload!
    content_type = detected_type
    unless ACCEPTED_TYPES.include?(content_type)
      raise Error.new("unsupported_image_type", "Images must be JPEG, PNG, or WebP.")
    end

    source = Vips::Image.new_from_file(@upload.tempfile.path, access: :sequential)
    width, height = oriented_dimensions(source)
    if width * height > MAX_SOURCE_PIXELS
      raise Error.new("image_dimensions_too_large", "The image dimensions are too large to process safely.")
    end

    extension = EXTENSIONS.fetch(content_type)
    pipeline = ImageProcessing::Vips.source(@upload.tempfile).autorot
    if width * height > @max_pixels
      target_width, target_height = target_dimensions(width, height)
      pipeline = pipeline.resize_to_limit(target_width, target_height)
    end
    tempfile = pipeline.convert(extension).saver(**saver_options(content_type)).call

    if tempfile.size > MAX_BYTES
      tempfile.close!
      raise Error.new("image_too_large", "The normalized image must be 8 MiB or smaller.")
    end

    normalized = Vips::Image.new_from_file(tempfile.path, access: :sequential)
    Result.new(
      tempfile: tempfile,
      filename: normalized_filename(extension),
      content_type: content_type,
      width: normalized.width,
      height: normalized.height,
      original_filename: sanitized_filename
    )
  rescue Error
    raise
  rescue Vips::Error => e
    Rails.logger.warn("ImageAttachmentProcessor: #{e.class}: #{e.message}")
    raise Error.new("invalid_image", "The image could not be decoded or normalized.")
  ensure
    @upload.tempfile.rewind if @upload.respond_to?(:tempfile) && @upload.tempfile.respond_to?(:rewind)
  end

  private

  def validate_upload!
    unless @upload.respond_to?(:tempfile) && @upload.tempfile.respond_to?(:path)
      raise Error.new("missing_file", "An image file is required.")
    end
    if @upload.size > MAX_BYTES
      raise Error.new("image_too_large", "Each image must be 8 MiB or smaller.")
    end
  end

  def detected_type
    @upload.tempfile.rewind
    Marcel::MimeType.for(@upload.tempfile)
  ensure
    @upload.tempfile.rewind
  end

  def oriented_dimensions(image)
    orientation = image.get_typeof("orientation").zero? ? 1 : image.get("orientation").to_i
    [ 5, 6, 7, 8 ].include?(orientation) ? [ image.height, image.width ] : [ image.width, image.height ]
  end

  def target_dimensions(width, height)
    scale = Math.sqrt(@max_pixels.to_f / (width * height))
    [ [ (width * scale).floor, 1 ].max, [ (height * scale).floor, 1 ].max ]
  end

  def saver_options(content_type)
    return { strip: true, Q: 95, optimize_coding: true } if content_type == "image/jpeg"
    return { strip: true, Q: 95 } if content_type == "image/webp"

    { strip: true }
  end

  def sanitized_filename
    ActiveStorage::Filename.new(@upload.original_filename.presence || "image").sanitized
  end

  def normalized_filename(extension)
    stem = File.basename(sanitized_filename, File.extname(sanitized_filename)).presence || "image"
    "#{stem}.#{extension}"
  end
end
