module Api
  class ProjectsController < ApplicationController
    before_action :authenticate_api_user!

    def index
      render json: {
        projects: current_api_user.projects.order(:name, :id).map { |project| serialize(project) },
        limits: { name: Project::MAX_NAME_LENGTH, description: Project::MAX_DESCRIPTION_LENGTH }
      }
    end

    def create
      project = current_api_user.projects.new(project_params)
      save_project(project, :created)
    end

    def update
      project = current_api_user.projects.find(params[:id])
      project.assign_attributes(project_params)
      save_project(project, :ok)
    end

    def destroy
      current_api_user.projects.find(params[:id]).destroy!
      head :no_content
    end

    private

    def save_project(project, status)
      if project.save
        render json: serialize(project), status: status
      else
        render json: { errors: project.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def serialize(project)
      project.as_json(only: [ :id, :name, :description ])
    end

    def project_params
      params.require(:project).permit(:name, :description)
    end
  end
end
