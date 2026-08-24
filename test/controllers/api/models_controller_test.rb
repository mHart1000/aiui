require "test_helper"

class Api::ModelsControllerTest < ActionDispatch::IntegrationTest
  test "catalogue includes three-state image input and compatibility vision" do
    with_env("LLAMA_VISION" => "invalid") do
      get "/api/models"
    end

    assert_response :success
    models = response.parsed_body["models"]
    assert models.all? { |model| %w[supported unsupported unknown].include?(model["image_input"]) }
    assert models.all? { |model| model["vision"] == (model["image_input"] == "supported") }
  end

  test "refresh query resets local discovery" do
    refresh_values = []
    catalogue = lambda do |refresh: false|
      refresh_values << refresh
      [ { "id" => "local-llama", "image_input" => "unknown", "vision" => false } ]
    end

    AiModels.stub(:catalogue, catalogue) { get "/api/models?refresh=1" }

    assert_response :success
    assert_equal [ true ], refresh_values
  end
end
