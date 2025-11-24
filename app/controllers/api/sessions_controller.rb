module Api
  class SessionsController < Devise::SessionsController
    respond_to :json

    def create
      user = warden.authenticate!(auth_options)
      sign_in(user, store: false)

      token = request.env['warden-jwt_auth.token']
      render json: { user: user, token: token }, status: :ok
    end

    def destroy
      render json: { message: "Logged out" }, status: :ok
    end
  end
end
