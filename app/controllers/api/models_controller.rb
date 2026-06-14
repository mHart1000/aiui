require "net/http"

module Api
  class ModelsController < ApplicationController
    def index
      render json: { models: AI_MODELS }
    end

    def llama_context
      base_url = ENV["LLAMA_API_URL"] || "http://host.docker.internal:8080/v1"
      uri = URI("#{base_url}/models")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 2
      http.read_timeout = 3
      data = JSON.parse(http.get(uri.request_uri).body)
      meta = data.dig("data", 0, "meta") || {}
      render json: { n_ctx: meta["n_ctx"], n_ctx_train: meta["n_ctx_train"] }
    rescue => e
      render json: { error: e.message }, status: :bad_gateway
    end
  end
end
