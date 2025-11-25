module Api
  class SessionsController < Devise::SessionsController
    respond_to :json
    skip_before_action :verify_signed_out_user, only: :destroy

    def create
      creds = params[:user]

      email = creds[:email].to_s
      password = creds[:password].to_s

      user = User.find_for_database_authentication(email: email)

      if user&.valid_password?(password)
        sign_in(user, store: false)

        token = request.env['warden-jwt_auth.token']

        render json: { user: user, token: token }, status: :ok
      else
        render json: { error: 'Invalid email or password' }, status: :unauthorized
      end
    end

    def destroy
      render json: { message: 'Logged out' }, status: :ok
    end
  end
end
