require "image_processing/vips"
require "marcel"

class ImageAttachmentProcessor
  MAX_BYTES = 8.megabytes
  MAX_SOURCE_PIXELS = 100_000_000
  MAX_PIXELS = 6_000_000
  ACCEPTED_TYPES = %w[image/jpeg image/png].freeze
  EXTENSIONS = {
    "image/jpeg" => "jpg",
    "image/png" => "png"
  }.freeze

  Result = Data.define(:tempfile, :filename, :content_type, :width, :height) do
    def attachable
      {
        io: tempfile,
        filename: filename,
        content_type: content_type,
        identify: false,
      }
    end

    def close!
      tempfile.close!
    end
  end

  class Error < StandardError; end

  def self.call(upload:)
    new(upload: upload).call
  end

  def initialize(upload:)
    @upload = upload
  end

  def call
    tempfile = nil
    completed = false
    validate_upload!
    content_type = detected_type
    unless ACCEPTED_TYPES.include?(content_type)
      raise Error, "Images must be JPEG or PNG."
    end

    source = Vips::Image.new_from_file(@upload.tempfile.path, access: :sequential)
    width, height = oriented_dimensions(source)
    if width * height > MAX_SOURCE_PIXELS
      raise Error, "The image dimensions are too large to process safely."
    end

    extension = EXTENSIONS.fetch(content_type)
    pipeline = ImageProcessing::Vips.source(@upload.tempfile).autorot
    if width * height > MAX_PIXELS
      target_width, target_height = target_dimensions(width, height)
      pipeline = pipeline.resize_to_limit(target_width, target_height)
    end
    tempfile = pipeline.convert(extension).saver(**saver_options(content_type)).call

    if tempfile.size > MAX_BYTES
      tempfile.close!
      raise Error, "The normalized image must be 8 MiB or smaller."
    end

    normalized = Vips::Image.new_from_file(tempfile.path, access: :sequential)
    result = Result.new(
      tempfile: tempfile,
      filename: normalized_filename(extension),
      content_type: content_type,
      width: normalized.width,
      height: normalized.height
    )
    completed = true
    result
  rescue Error
    raise
  rescue Vips::Error => e
    Rails.logger.warn("ImageAttachmentProcessor: #{e.class}: #{e.message}")
    raise Error, "The image could not be decoded or normalized."
  ensure
    tempfile&.close! unless completed
    @upload.tempfile.rewind if @upload.respond_to?(:tempfile) && @upload.tempfile.respond_to?(:rewind)
  end

  private

  def validate_upload!
    unless @upload.respond_to?(:tempfile) && @upload.tempfile.respond_to?(:path)
      raise Error, "An image file is required."
    end
    if @upload.size > MAX_BYTES
      raise Error, "Each image must be 8 MiB or smaller."
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
    scale = Math.sqrt(MAX_PIXELS.to_f / (width * height))
    target_width = [ (width * scale).floor, 1 ].max
    target_height = [ (height * scale).floor, 1 ].max

    if target_width * target_height > MAX_PIXELS
      if target_width >= target_height
        target_width = [ (MAX_PIXELS / target_height).floor, 1 ].max
      else
        target_height = [ (MAX_PIXELS / target_width).floor, 1 ].max
      end
    end

    [ target_width, target_height ]
  end

  def saver_options(content_type)
    return { strip: true, Q: 95, optimize_coding: true } if content_type == "image/jpeg"

    { strip: true }
  end

  def sanitized_filename
    raw = (@upload.original_filename.presence || "image").to_s.tr("\\", "/")
    basename = File.basename(raw)
    ActiveStorage::Filename.new(basename).sanitized.sub(/\A[.\s-]+/, "").presence || "image"
  end

  def normalized_filename(extension)
    stem = File.basename(sanitized_filename, File.extname(sanitized_filename)).presence || "image"
    "#{stem}.#{extension}"
  end
end
