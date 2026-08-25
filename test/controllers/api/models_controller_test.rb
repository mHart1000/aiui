require "test_helper"

class Api::ModelsControllerTest < ActionDispatch::IntegrationTest
  test "catalogue is unchanged and local capability is top-level" do
    with_env("LLAMA_VISION" => "invalid") do
      get "/api/models"
    end

    assert_response :success
    models = response.parsed_body["models"]
    assert_nil response.parsed_body["local_image_input"]
    assert models.none? { |model| model.key?("image_input") || model.key?("vision") }
  end

  test "refresh query resets local discovery" do
    refresh_values = []
    capability = ->(refresh: false) { refresh_values << refresh; nil }

    AiModels.stub(:local_image_input, capability) { get "/api/models?refresh=1" }

    assert_response :success
    assert_equal [ true ], refresh_values
  end
end
