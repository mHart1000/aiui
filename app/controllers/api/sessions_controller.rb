module Api
  class SessionsController < Devise::SessionsController
    before_action :ensure_json_request
    respond_to :json

    def create
      resource = warden.authenticate!(auth_options)
      token = Warden::JWTAuth::UserEncoder.new.call(resource, :user, nil).first
      render json: { user: resource, token: token }, status: :ok
    end

    def destroy
      render json: { message: "Logged out" }, status: :ok
    end

    private

    def ensure_json_request
      request.format = :json
    end
  end
end
