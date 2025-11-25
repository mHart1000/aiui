module Api
  class RegistrationsController < Devise::RegistrationsController
    respond_to :json

    def create
      resource = User.new(sign_up_params)

      if resource.save
        sign_in(resource, store: false)
        token = request.env["warden-jwt_auth.token"]
        render json: { user: resource, token: token }, status: :ok
      else
        render json: { errors: resource.errors.full_messages }, status: :unprocessable_entity
      end
    end

    private

    def sign_up_params
      params.require(:user).permit(:email, :password, :password_confirmation)
    end
  end
end
