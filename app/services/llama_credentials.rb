# llama.cpp API key, stored in Rails credentials as `llama_api_key`.
module LlamaCredentials
  # Sets the Authorization header. No key means no header, which is safe:
  # servers without --api-key don't check auth at all.
  def self.authorize(request)
    key = Rails.application.credentials[:llama_api_key]
    request["Authorization"] = "Bearer #{key}" if key.present?
  end
end
