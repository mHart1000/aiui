require "test_helper"

class AiModelsTest < ActiveSupport::TestCase
  test "local identity comes from the catalogue" do
    assert AiModels.local?("local-llama")
    assert_not AiModels.local?("openrouter/meta-llama/llama-3.3-70b-instruct:free")
    assert_not AiModels.local?("not-a-real-model")
  end

  test "all non-local models reject new images" do
    AiModels.stub(:local_image_input, true) do
      assert_not AiModels.images_allowed?("openrouter/google/gemma-4-31b-it:free")
      assert_not AiModels.images_allowed?("openrouter/nvidia/nemotron-nano-12b-v2-vl:free")
      assert_not AiModels.images_allowed?("claude-opus-4-5")
      assert_not AiModels.images_allowed?(nil)
    end
  end

  test "local image input reads llama.cpp's model capabilities" do
    response = { models: [ { capabilities: [ "completion", "multimodal" ] } ] }.to_json

    Net::HTTP.stub(:get, response) do
      assert AiModels.local_image_input
    end
  end

  test "missing or unavailable capabilities fail open" do
    Net::HTTP.stub(:get, { models: [ {} ] }.to_json) do
      assert_nil AiModels.local_image_input
      assert AiModels.images_allowed?("local-llama")
    end

    Net::HTTP.stub(:get, ->(*) { raise Errno::ECONNREFUSED }) do
      assert_nil AiModels.local_image_input
      assert AiModels.images_allowed?("local-llama")
    end
  end
end
