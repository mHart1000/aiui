require "test_helper"

class ImageCapabilityServiceTest < ActiveSupport::TestCase
  setup { ImageCapabilityService.clear_cache! }

  test "llama capability comes from props vision modality" do
    service = ImageCapabilityService.new(model_code: "local-llama")

    service.stub(:get_json, { "modalities" => { "vision" => true } }) do
      result = service.call
      assert_equal "supported", result[:image_input]
      assert_equal "llama_props", result[:source]
    end
  end

  test "missing llama vision modality is unknown" do
    service = ImageCapabilityService.new(model_code: "local-llama")

    service.stub(:get_json, { "modalities" => {} }) do
      assert_equal "unknown", service.call[:image_input]
    end
  end

  test "llama lookup failures are unknown" do
    service = ImageCapabilityService.new(model_code: "local-llama")

    service.stub(:get_json, ->(*) { raise Timeout::Error, "timeout" }) do
      assert_equal "unknown", service.call[:image_input]
    end
  end

  test "OpenRouter matches the exact model and reads image input modalities" do
    service = ImageCapabilityService.new(model_code: "openrouter/google/gemma-3-27b-it")
    response = {
      "data" => [
        {
          "id" => "google/gemma-3-27b-it",
          "architecture" => { "input_modalities" => %w[text image] }
        }
      ]
    }

    service.stub(:get_json, response) do
      assert_equal "supported", service.call[:image_input]
    end
  end

  test "OpenRouter missing exact model is unknown" do
    service = ImageCapabilityService.new(model_code: "openrouter/google/gemma-3-27b-it")
    service.stub(:get_json, { "data" => [] }) do
      assert_equal "unknown", service.call[:image_input]
    end
  end

  test "out of scope adapters are unsupported without a network request" do
    service = ImageCapabilityService.new(model_code: "gpt-4o")
    service.stub(:get_json, ->(*) { flunk("network lookup should not run") }) do
      assert_equal "unsupported", service.call[:image_input]
    end
  end

  test "refresh bypasses a cached result" do
    first = ImageCapabilityService.new(model_code: "local-llama")
    first.stub(:get_json, { "modalities" => { "vision" => false } }) { first.call }

    refreshed = ImageCapabilityService.new(model_code: "local-llama", refresh: true)
    refreshed.stub(:get_json, { "modalities" => { "vision" => true } }) do
      assert_equal "supported", refreshed.call[:image_input]
    end
  end
end
