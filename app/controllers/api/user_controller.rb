module Api
  class UserController < ApplicationController
    before_action :authenticate_api_user!

    def show
      render json: {
        id: current_api_user.id,
        email: current_api_user.email,
        use_scaffolding: current_api_user.use_scaffolding
      }
    end

    def update
      if current_api_user.update(user_params)
        render json: {
          id: current_api_user.id,
          email: current_api_user.email,
          use_scaffolding: current_api_user.use_scaffolding
        }
      else
        render json: { errors: current_api_user.errors.full_messages }, status: :unprocessable_entity
      end
    end

    private

    def user_params
      params.require(:user).permit(:use_scaffolding)
    end
  end
end
