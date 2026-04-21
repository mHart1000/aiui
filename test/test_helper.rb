ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

class ActiveSupport::TestCase
  # Run tests serially. Parallelization has caused DRb marshal failures on CI
  # when a worker raises an exception whose context can't be Marshal.dump'd
  # (e.g. anything closing over a Binding). Past attempts to pin single files
  # (see 1c57377) kept leaking as new tests were added — serial is cheap here.
  parallelize(workers: 1)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  def with_env(vars)
    originals = vars.keys.each_with_object({}) { |k, h| h[k] = ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| ENV[k] = v }
  end
end

class ActionDispatch::IntegrationTest
  def sign_in_as(user)
    post "/api/login", params: { user: { email: user.email, password: "password123" } }, as: :json
    token = JSON.parse(response.body)["token"]
    { "Authorization" => "Bearer #{token}" }
  end
end
