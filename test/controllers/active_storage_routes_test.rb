require "test_helper"

class ActiveStorageRoutesTest < ActiveSupport::TestCase
  test "generated Active Storage blob routes are enabled" do
    route = Rails.application.routes.recognize_path(
      "/rails/active_storage/blobs/redirect/token/file.png"
    )

    assert_equal "active_storage/blobs/redirect", route[:controller]
    assert_equal "show", route[:action]
  end
end
