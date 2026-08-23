require "test_helper"
require "tempfile"

class ImageAttachmentProcessorTest < ActiveSupport::TestCase
  VIPS_AVAILABLE = begin
    require "vips"
    true
  rescue LoadError
    false
  end

  setup { skip "libvips is not installed" unless VIPS_AVAILABLE }

  test "normalizes an accepted image and records dimensions" do
    upload = uploaded_file(Vips::Image.black(1, 1).write_to_buffer(".png"), "pixel.png", "image/png")
    result = ImageAttachmentProcessor.call([ upload ]).first

    assert_equal "image/png", result.content_type
    assert_equal 1, result.width
    assert_equal 1, result.height
    assert_equal "pixel.png", result.filename
  ensure
    result&.close!
    upload&.tempfile&.close!
  end

  test "resizes the longest edge to 2048 pixels without upscaling" do
    bytes = Vips::Image.black(3000, 1000).write_to_buffer(".jpg")
    upload = uploaded_file(bytes, "wide.jpg", "image/jpeg")
    result = ImageAttachmentProcessor.call([ upload ]).first

    assert_equal 2048, result.width
    assert_equal 683, result.height
    assert_equal "image/jpeg", result.content_type
  ensure
    result&.close!
    upload&.tempfile&.close!
  end

  test "rejects a decoded format outside the allowlist" do
    bytes = Vips::Image.black(1, 1).write_to_buffer(".gif")
    upload = uploaded_file(bytes, "pixel.gif", "image/gif")

    error = assert_raises(ImageAttachmentProcessor::Error) do
      ImageAttachmentProcessor.call([ upload ])
    end
    assert_equal "unsupported_image_type", error.code
  ensure
    upload&.tempfile&.close!
  end

  test "rejects corrupt image bytes as invalid" do
    upload = uploaded_file("not an image", "broken.png", "image/png")

    error = assert_raises(ImageAttachmentProcessor::Error) do
      ImageAttachmentProcessor.call([ upload ])
    end
    assert_equal "invalid_image", error.code
  ensure
    upload&.tempfile&.close!
  end

  test "rejects more than four images before processing" do
    error = assert_raises(ImageAttachmentProcessor::Error) do
      ImageAttachmentProcessor.call(Array.new(5, Object.new))
    end
    assert_equal "too_many_images", error.code
  end

  private

  def uploaded_file(bytes, filename, content_type)
    tempfile = Tempfile.new([ "upload", File.extname(filename) ])
    tempfile.binmode
    tempfile.write(bytes)
    tempfile.rewind
    ActionDispatch::Http::UploadedFile.new(
      tempfile: tempfile,
      filename: filename,
      type: content_type
    )
  end
end
