require "test_helper"

module Api
  class ModelsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "models_#{SecureRandom.hex(4)}@example.com", password: "password123")
      @headers = sign_in_as(@user)
    end

    test "image capability requires authentication" do
      get "/api/models/image_capability", params: { model_code: "local-llama" }
      assert_response :unauthorized
    end

    test "image capability returns the provider discovery result" do
      result = { model_code: "local-llama", image_input: "supported", source: "llama_props" }
      ImageCapabilityService.stub(:call, result) do
        get "/api/models/image_capability",
          params: { model_code: "local-llama" },
          headers: @headers
      end

      assert_response :success
      assert_equal result.stringify_keys, JSON.parse(response.body)
    end
  end
end
