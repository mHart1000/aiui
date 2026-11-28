require "test_helper"

class Api::ModelsControllerTest < ActionDispatch::IntegrationTest
  test "catalogue includes the local model capability" do
    AiModels.stub(:local_image_input, false) do
      get "/api/models"
    end

    assert_response :success
    models = response.parsed_body["models"]
    assert models.any? { |model| model["id"] == "custom-llama" && model["owned_by"] == "local" }
    assert_equal false, response.parsed_body["local_image_input"]
    assert models.none? { |model| model.key?("image_input") || model.key?("vision") }
  end

  test "llama context includes models reported by llama.cpp" do
    response_body = {
      data: [
        { id: "model-a", meta: { n_ctx: 32_768, n_ctx_train: 131_072 } },
        { id: "model-b" }
      ]
    }.to_json
    http = Minitest::Mock.new
    http.expect :open_timeout=, 2, [ 2 ]
    http.expect :read_timeout=, 3, [ 3 ]
    http.expect :request, Struct.new(:body).new(response_body), [ Net::HTTP::Get ]

    Net::HTTP.stub(:new, http) do
      get "/api/models/llama_context"
    end

    assert_response :success
    assert_equal [ "model-a", "model-b" ], response.parsed_body["models"]
    assert_equal 32_768, response.parsed_body["n_ctx"]
    http.verify
  end
end
