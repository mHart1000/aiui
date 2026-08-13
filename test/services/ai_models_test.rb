require "test_helper"

class AiModelsTest < ActiveSupport::TestCase
  test "local? reads the catalogue instead of matching the id string" do
    assert AiModels.local?("local-llama")
    # A cloud id containing "llama" must not be mistaken for the local model.
    assert_not AiModels.local?("openrouter/meta-llama/llama-3.3-70b-instruct:free")
    assert_not AiModels.local?("not-a-real-model")
  end

  test "cloud vision comes from the allowlist" do
    assert AiModels.vision?("openrouter/google/gemma-4-31b-it:free")
    assert AiModels.vision?("openrouter/nvidia/nemotron-nano-12b-v2-vl:free")
    assert_not AiModels.vision?("openrouter/qwen/qwen3-coder:free")
    assert_not AiModels.vision?("claude-opus-4-5")
    assert_not AiModels.vision?(nil)
  end

  test "LLAMA_VISION overrides detection in both directions" do
    LlamaCapabilities.stub(:vision?, false) do
      with_env("LLAMA_VISION" => "true") { assert AiModels.vision?("local-llama") }
    end
    LlamaCapabilities.stub(:vision?, true) do
      with_env("LLAMA_VISION" => "false") { assert_not AiModels.vision?("local-llama") }
    end
  end

  test "local vision follows llama.cpp when no override is set" do
    with_env("LLAMA_VISION" => nil) do
      LlamaCapabilities.stub(:vision?, true) { assert AiModels.vision?("local-llama") }
      LlamaCapabilities.stub(:vision?, false) { assert_not AiModels.vision?("local-llama") }
    end
  end

  test "catalogue merges a vision flag onto every entry" do
    with_env("LLAMA_VISION" => "false") do
      catalogue = AiModels.catalogue

      assert catalogue.all? { |model| model.key?("vision") }
      assert_equal true, catalogue.find { |m| m["id"] == "openrouter/google/gemma-3-27b-it:free" }["vision"]
      assert_equal false, catalogue.find { |m| m["id"] == "gpt-4" }["vision"]
    end
  end
end
