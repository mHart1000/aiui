module Api
  class SkillsController < ApplicationController
    before_action :authenticate_api_user!

    def index
      render json: current_api_user.skills.order(:id).map { |s| serialize(s) }
    end

    def create
      skill = current_api_user.skills.new(skill_params)
      if skill.save
        render json: serialize(skill), status: :created
      else
        render json: { errors: skill.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      skill = current_api_user.skills.find(params[:id])
      if skill.update(skill_params)
        render json: serialize(skill)
      else
        render json: { errors: skill.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      current_api_user.skills.find(params[:id]).destroy!
      head :no_content
    end

    private

    def serialize(skill)
      {
        id: skill.id,
        name: skill.name,
        description: skill.description,
        body: skill.body,
        enabled_by_default: skill.enabled_by_default,
        updated_at: skill.updated_at
      }
    end

    def skill_params
      params.require(:skill).permit(:name, :description, :body, :enabled_by_default)
    end
  end
end
