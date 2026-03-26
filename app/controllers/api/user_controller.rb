module Api
  class UserController < ApplicationController
    before_action :authenticate_api_user!

    def show
      render json: {
        id: current_api_user.id,
        email: current_api_user.email,
        use_scaffolding: current_api_user.use_scaffolding,
        tts_enabled: current_api_user.tts_enabled,
        tts_voice: current_api_user.tts_voice || "af_heart",
        tts_speed: current_api_user.tts_speed
      }
    end

    def update
      if current_api_user.update(user_params)
        render json: {
          id: current_api_user.id,
          email: current_api_user.email,
          use_scaffolding: current_api_user.use_scaffolding,
          tts_enabled: current_api_user.tts_enabled,
          tts_voice: current_api_user.tts_voice || "af_heart",
          tts_speed: current_api_user.tts_speed
        }
      else
        render json: { errors: current_api_user.errors.full_messages }, status: :unprocessable_entity
      end
    end

    private

    def user_params
      params.require(:user).permit(:use_scaffolding, :tts_enabled, :tts_voice, :tts_speed)
    end
  end
end
