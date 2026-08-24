require "test_helper"

class ActiveStorageRoutesTest < ActiveSupport::TestCase
  test "generated Active Storage routes are disabled" do
    assert_equal false, Rails.application.config.active_storage.draw_routes
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/rails/active_storage/blobs/redirect/token/file.png")
    end
  end
end
