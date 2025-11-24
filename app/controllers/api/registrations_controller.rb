module Api
  class RegistrationsController < Devise::RegistrationsController
    respond_to :json

    private

    def respond_with(resource, _opts = {})
      render json: { user: resource, token: request.env['warden-jwt_auth.token'] }, status: :ok
    end
  end
end
