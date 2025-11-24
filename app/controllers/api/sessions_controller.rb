module Api
  class SessionsController < Devise::SessionsController
    respond_to :json

    private

    def respond_with(resource, _opts = {})
      render json: { user: resource, token: request.env['warden-jwt_auth.token'] }, status: :ok
    end

    def respond_to_on_destroy
      render json: { message: "Logged out." }, status: :ok
    end
  end
end
