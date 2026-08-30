require "test_helper"

class Api::ModelsControllerTest < ActionDispatch::IntegrationTest
  test "catalogue includes the local model capability" do
    AiModels.stub(:local_image_input, false) do
      get "/api/models"
    end

    assert_response :success
    models = response.parsed_body["models"]
    assert_equal false, response.parsed_body["local_image_input"]
    assert models.none? { |model| model.key?("image_input") || model.key?("vision") }
  end
end
