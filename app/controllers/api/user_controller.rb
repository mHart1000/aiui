module Api
  class UserController < ApplicationController
    before_action :authenticate_api_user!

    def show
      render json: user_json
    end

    def update
      attrs = user_params
      if attrs.key?(:persona_id) && !Persona.ids.include?(attrs[:persona_id])
        return render json: { errors: [ "Persona '#{attrs[:persona_id]}' is not registered" ] }, status: :unprocessable_entity
      end

      if current_api_user.update(attrs)
        render json: user_json
      else
        code = attrs.key?(:image_max_pixels) ? "invalid_pixel_budget" : "invalid_user_settings"
        render json: {
          error: { code: code, message: current_api_user.errors.full_messages.to_sentence }
        }, status: :unprocessable_entity
      end
    end

    private

    def user_json
      {
        id: current_api_user.id,
        email: current_api_user.email,
        use_scaffolding: current_api_user.use_scaffolding,
        use_persona: current_api_user.use_persona,
        persona_id: current_api_user.persona_id,
        personas: Persona.all.map { |p| { id: p.id, name: p.name, description: p.description } },
        use_skills: current_api_user.use_skills,
        default_skill_ids: current_api_user.skills.where(enabled_by_default: true).order(:id).pluck(:id),
        tts_enabled: current_api_user.tts_enabled,
        tts_voice: current_api_user.tts_voice || "af_heart",
        tts_speed: current_api_user.tts_speed,
        llama_context_window: current_api_user.llama_context_window,
        image_max_pixels: current_api_user.image_max_pixels
      }
    end

    def user_params
      params.require(:user).permit(:use_scaffolding, :use_persona, :persona_id, :use_skills, :tts_enabled, :tts_voice, :tts_speed, :llama_context_window, :image_max_pixels)
    end
  end
end
