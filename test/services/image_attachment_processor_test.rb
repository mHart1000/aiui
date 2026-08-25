require "test_helper"
require "tempfile"

class ImageAttachmentProcessorTest < ActiveSupport::TestCase
  def uploaded_file(bytes: nil, fixture: nil, filename: "image.bin", type: "application/octet-stream")
    tempfile = Tempfile.new([ "image-upload", File.extname(filename) ], binmode: true)
    tempfile.write(bytes || File.binread(file_fixture(fixture)))
    tempfile.rewind
    ActionDispatch::Http::UploadedFile.new(
      tempfile: tempfile,
      filename: filename,
      type: type
    )
  end

  def process(upload)
    ImageAttachmentProcessor.call(upload: upload)
  end

  test "detects MIME from bytes and corrects a hostile filename extension" do
    upload = uploaded_file(fixture: "small.png", filename: "../unsafe name.jpg", type: "image/jpeg")
    result = process(upload)

    assert_equal "image/png", result.content_type
    assert_equal "unsafe name.png", result.filename
    assert_equal [ 100, 80 ], [ result.width, result.height ]
  ensure
    result&.close!
    upload&.tempfile&.close!
  end

  test "rejects GIF even when its declared MIME is allowed" do
    upload = uploaded_file(bytes: "GIF89a".b + ("\0" * 32), filename: "animated.gif", type: "image/png")

    error = assert_raises(ImageAttachmentProcessor::Error) { process(upload) }
    assert_equal "unsupported_image_type", error.code
  ensure
    upload&.tempfile&.close!
  end

  test "rejects corrupt data with an actionable code" do
    upload = uploaded_file(bytes: "\xFF\xD8\xFF\xE0broken".b, filename: "broken.jpg", type: "image/jpeg")

    error = assert_raises(ImageAttachmentProcessor::Error) { process(upload) }
    assert_equal "invalid_image", error.code
  ensure
    upload&.tempfile&.close!
  end

  test "rejects input above eight MiB before decoding" do
    upload = uploaded_file(bytes: "\0" * (ImageAttachmentProcessor::MAX_BYTES + 1), filename: "huge.png", type: "image/png")

    error = assert_raises(ImageAttachmentProcessor::Error) { process(upload) }
    assert_equal "image_too_large", error.code
  ensure
    upload&.tempfile&.close!
  end

  test "rejects and cleans up normalized output above eight MiB" do
    upload = uploaded_file(fixture: "small.png", filename: "small.png", type: "image/png")
    oversized = Tempfile.new([ "normalized", ".png" ], binmode: true)
    oversized.write("\0" * (ImageAttachmentProcessor::MAX_BYTES + 1))
    oversized.rewind
    output_path = oversized.path
    pipeline = Object.new
    %i[autorot convert saver].each do |method|
      pipeline.define_singleton_method(method) { |*_args, **_kwargs| self }
    end
    pipeline.define_singleton_method(:call) { oversized }

    ImageProcessing::Vips.stub(:source, ->(*) { pipeline }) do
      error = assert_raises(ImageAttachmentProcessor::Error) { process(upload) }
      assert_equal "image_too_large", error.code
    end
    assert_not File.exist?(output_path)
  ensure
    oversized&.close!
    upload&.tempfile&.close!
  end

  test "rejects source dimensions above one hundred million pixels" do
    upload = uploaded_file(fixture: "small.png", filename: "small.png", type: "image/png")
    fake = Struct.new(:width, :height) do
      def get_typeof(_name) = 0
    end.new(10_001, 10_000)

    Vips::Image.stub(:new_from_file, fake) do
      error = assert_raises(ImageAttachmentProcessor::Error) { process(upload) }
      assert_equal "image_dimensions_too_large", error.code
    end
  ensure
    upload&.tempfile&.close!
  end

  test "keeps dimensions below the cap while re-encoding and stripping metadata" do
    upload = uploaded_file(fixture: "small.png", filename: "small.png", type: "image/png")
    result = process(upload)
    image = Vips::Image.new_from_file(result.tempfile.path)

    assert_equal [ 100, 80 ], [ image.width, image.height ]
    assert_empty image.get_fields.grep(/exif|xmp|comment|gps/i)
    assert_operator result.tempfile.size, :<=, ImageAttachmentProcessor::MAX_BYTES
  ensure
    result&.close!
    upload&.tempfile&.close!
  end

  test "resizes close to but never above the fixed budget" do
    upload = uploaded_file(fixture: "large.jpg", filename: "large.jpg", type: "image/jpeg")
    result = process(upload)
    pixels = result.width * result.height

    assert_operator pixels, :<=, ImageAttachmentProcessor::MAX_PIXELS
    assert_operator pixels, :>, ImageAttachmentProcessor::MAX_PIXELS * 0.99
    assert_in_delta 1.25, result.width.to_f / result.height, 0.01
  ensure
    result&.close!
    upload&.tempfile&.close!
  end

  test "rejects WebP" do
    source = Tempfile.new([ "alpha", ".webp" ], binmode: true)
    Vips::Image.black(12, 8, bands: 4).new_from_image([ 255, 10, 20, 100 ]).write_to_file(source.path, Q: 100)
    upload = ActionDispatch::Http::UploadedFile.new(tempfile: source, filename: "alpha.webp", type: "image/webp")
    error = assert_raises(ImageAttachmentProcessor::Error) { process(upload) }
    assert_equal "unsupported_image_type", error.code
  ensure
    source&.close!
  end

  test "bakes EXIF orientation and strips the orientation tag" do
    source = Tempfile.new([ "oriented", ".jpg" ], binmode: true)
    image = Vips::Image.black(40, 20).new_from_image([ 200, 100, 50 ])
    image.set_type(GObject::GINT_TYPE, "orientation", 6)
    image.set_type(
      GObject::GSTR_TYPE,
      "exif-ifd3-GPSLatitude",
      "37/1 46/1 0/1 (37.7667, ASCII, 17 bytes)"
    )
    image.write_to_file(source.path, Q: 95)
    source.rewind
    assert_operator Vips::Image.new_from_file(source.path).get_typeof("exif-ifd3-GPSLatitude"), :>, 0
    upload = ActionDispatch::Http::UploadedFile.new(tempfile: source, filename: "oriented.jpg", type: "image/jpeg")
    result = process(upload)
    normalized = Vips::Image.new_from_file(result.tempfile.path)

    assert_equal [ 20, 40 ], [ result.width, result.height ]
    assert_equal 0, normalized.get_typeof("orientation")
    assert_empty normalized.get_fields.grep(/exif|xmp|comment|gps/i)
  ensure
    result&.close!
    source&.close!
  end

  test "guards extreme aspect ratios against a zero target dimension" do
    processor = ImageAttachmentProcessor.new(upload: nil)
    width, height = processor.send(:target_dimensions, 100_000_000, 1)

    assert_operator width, :>=, 1
    assert_operator height, :>=, 1
    assert_operator width * height, :<=, ImageAttachmentProcessor::MAX_PIXELS
  end
end
