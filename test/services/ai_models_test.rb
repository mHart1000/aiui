require "test_helper"

class AiModelsTest < ActiveSupport::TestCase
  test "local identity comes from the catalogue" do
    assert AiModels.local?("local-llama")
    assert_not AiModels.local?("openrouter/meta-llama/llama-3.3-70b-instruct:free")
    assert_not AiModels.local?("not-a-real-model")
  end

  test "cloud image support comes only from the static allowlist" do
    assert_equal "supported", AiModels.image_input("openrouter/google/gemma-4-31b-it:free")
    assert_equal "supported", AiModels.image_input("openrouter/nvidia/nemotron-nano-12b-v2-vl:free")
    assert_equal "unsupported", AiModels.image_input("openrouter/qwen/qwen3-coder:free")
    assert_equal "unsupported", AiModels.image_input("claude-opus-4-5")
    assert_equal "unsupported", AiModels.image_input(nil)
  end

  test "LLAMA_VISION overrides local discovery in both directions" do
    with_env("LLAMA_VISION" => "true") do
      LlamaCapabilities.stub(:image_input, "unsupported") do
        assert_equal "supported", AiModels.image_input("local-llama")
      end
    end
    with_env("LLAMA_VISION" => "false") do
      LlamaCapabilities.stub(:image_input, "supported") do
        assert_equal "unsupported", AiModels.image_input("local-llama")
      end
    end
  end

  test "invalid LLAMA_VISION values are unknown" do
    with_env("LLAMA_VISION" => "sometimes") do
      assert_equal "unknown", AiModels.image_input("local-llama")
      assert_not AiModels.vision?("local-llama")
    end
  end

  test "local image input follows all discovery states without an override" do
    with_env("LLAMA_VISION" => nil) do
      %w[supported unsupported unknown].each do |status|
        LlamaCapabilities.stub(:image_input, status) do
          assert_equal status, AiModels.image_input("local-llama")
        end
      end
    end
  end

  test "catalogue exposes image_input and compatibility vision" do
    with_env("LLAMA_VISION" => "unknown-value") do
      catalogue = AiModels.catalogue
      local = catalogue.find { |model| model["id"] == "local-llama" }
      cloud = catalogue.find { |model| model["id"] == "openrouter/google/gemma-3-27b-it:free" }
      text = catalogue.find { |model| model["id"] == "gpt-4" }

      assert catalogue.all? { |model| model.key?("image_input") && model.key?("vision") }
      assert_equal "unknown", local["image_input"]
      assert_equal false, local["vision"]
      assert_equal [ "supported", true ], [ cloud["image_input"], cloud["vision"] ]
      assert_equal [ "unsupported", false ], [ text["image_input"], text["vision"] ]
    end
  end

  test "catalogue refresh is forwarded to local discovery" do
    calls = []
    with_env("LLAMA_VISION" => nil) do
      LlamaCapabilities.stub(:image_input, ->(refresh: false) { calls << refresh; "unknown" }) do
        AiModels.catalogue(refresh: true)
      end
    end

    assert_equal [ true ], calls
  end

  test "refresh resets discovery even while an override is active" do
    resets = 0
    with_env("LLAMA_VISION" => "true") do
      LlamaCapabilities.stub(:reset!, -> { resets += 1 }) do
        AiModels.catalogue(refresh: true)
      end
    end

    assert_equal 1, resets
  end
end
