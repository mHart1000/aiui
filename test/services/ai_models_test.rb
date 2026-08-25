require "test_helper"

class AiModelsTest < ActiveSupport::TestCase
  test "local identity comes from the catalogue" do
    assert AiModels.local?("local-llama")
    assert_not AiModels.local?("openrouter/meta-llama/llama-3.3-70b-instruct:free")
    assert_not AiModels.local?("not-a-real-model")
  end

  test "all non-local models reject new images" do
    LlamaCapabilities.stub(:image_input, true) do
      assert_not AiModels.images_allowed?("openrouter/google/gemma-4-31b-it:free")
      assert_not AiModels.images_allowed?("openrouter/nvidia/nemotron-nano-12b-v2-vl:free")
      assert_not AiModels.images_allowed?("claude-opus-4-5")
      assert_not AiModels.images_allowed?(nil)
    end
  end

  test "LLAMA_VISION overrides local discovery in both directions" do
    with_env("LLAMA_VISION" => "true") do
      LlamaCapabilities.stub(:image_input, false) do
        assert_equal true, AiModels.local_image_input
        assert AiModels.images_allowed?("local-llama")
      end
    end
    with_env("LLAMA_VISION" => "false") do
      LlamaCapabilities.stub(:image_input, true) do
        assert_equal false, AiModels.local_image_input
        assert_not AiModels.images_allowed?("local-llama")
      end
    end
  end

  test "invalid LLAMA_VISION values fail open" do
    with_env("LLAMA_VISION" => "sometimes") do
      assert_nil AiModels.local_image_input
      assert AiModels.images_allowed?("local-llama")
    end
  end

  test "local image input follows nullable discovery" do
    with_env("LLAMA_VISION" => nil) do
      [ true, false, nil ].each do |status|
        LlamaCapabilities.stub(:image_input, status) do
          if status.nil?
            assert_nil AiModels.local_image_input
          else
            assert_equal status, AiModels.local_image_input
          end
          assert_equal status != false, AiModels.images_allowed?("local-llama")
        end
      end
    end
  end

  test "refresh is forwarded to local discovery" do
    calls = []
    with_env("LLAMA_VISION" => nil) do
      LlamaCapabilities.stub(:image_input, ->(refresh: false) { calls << refresh; nil }) do
        AiModels.local_image_input(refresh: true)
      end
    end

    assert_equal [ true ], calls
  end

  test "refresh resets discovery while an override is active" do
    resets = 0
    with_env("LLAMA_VISION" => "true") do
      LlamaCapabilities.stub(:reset!, -> { resets += 1 }) do
        AiModels.local_image_input(refresh: true)
      end
    end

    assert_equal 1, resets
  end
end
