module Api
  class ModelsController < ApplicationController
    def index
      render json: { models: AI_MODELS }
    end
  end
end
