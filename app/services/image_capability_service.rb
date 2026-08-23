require "json"
require "net/http"
require "uri"

class ImageCapabilityService
  LLAMA_SUCCESS_TTL = 30.seconds
  LLAMA_FAILURE_TTL = 10.seconds
  OPENROUTER_SUCCESS_TTL = 1.hour
  OPENROUTER_FAILURE_TTL = 30.seconds
  OPENROUTER_MODELS_URL = "https://openrouter.ai/api/v1/models"

  @cache = {}
  @cache_mutex = Mutex.new

  class << self
    attr_reader :cache, :cache_mutex

    def call(model_code:, refresh: false)
      new(model_code: model_code, refresh: refresh).call
    end

    def clear_cache!
      cache_mutex.synchronize { cache.clear }
    end
  end

  def initialize(model_code:, refresh: false)
    @model_code = model_code.to_s
    @refresh = refresh
  end

  def call
    unless @refresh
      cached = self.class.cache_mutex.synchronize { self.class.cache[@model_code] }
      return cached[:value] if cached && cached[:expires_at] > monotonic_now
    end

    value, ttl = discover
    value = value.merge(model_code: @model_code)
    self.class.cache_mutex.synchronize do
      self.class.cache[@model_code] = { value: value, expires_at: monotonic_now + ttl }
    end
    value
  end

  private

  def discover
    if @model_code.downcase.start_with?("openrouter/")
      discover_openrouter
    elsif llama_model?
      discover_llama
    else
      [ { image_input: "unsupported", source: "unsupported_adapter" }, LLAMA_SUCCESS_TTL ]
    end
  end

  def llama_model?
    code = @model_code.downcase
    code.include?("llama") || code.include?("local") || code.end_with?(".gguf")
  end

  def discover_llama
    base_url = ENV["LLAMA_API_URL"].presence || "http://host.docker.internal:8080/v1"
    root = base_url.sub(%r{/v1/?\z}, "").sub(%r{/\z}, "")
    props = get_json(URI("#{root}/props"))
    vision = props.dig("modalities", "vision")
    if vision == true || vision == false
      [ { image_input: vision ? "supported" : "unsupported", source: "llama_props" }, LLAMA_SUCCESS_TTL ]
    else
      [ { image_input: "unknown", source: "llama_props" }, LLAMA_FAILURE_TTL ]
    end
  rescue => e
    log_failure("llama.cpp", e)
    [ { image_input: "unknown", source: "llama_props" }, LLAMA_FAILURE_TTL ]
  end

  def discover_openrouter
    headers = {}
    headers["Authorization"] = "Bearer #{ENV['OPENROUTER_API_KEY']}" if ENV["OPENROUTER_API_KEY"].present?
    payload = get_json(URI(OPENROUTER_MODELS_URL), headers: headers)
    model_id = @model_code.delete_prefix("openrouter/")
    model = Array(payload["data"]).find { |candidate| candidate["id"] == model_id }
    modalities = model&.dig("architecture", "input_modalities")

    if modalities.is_a?(Array)
      supported = modalities.include?("image")
      [ { image_input: supported ? "supported" : "unsupported", source: "openrouter_models" }, OPENROUTER_SUCCESS_TTL ]
    else
      [ { image_input: "unknown", source: "openrouter_models" }, OPENROUTER_FAILURE_TTL ]
    end
  rescue => e
    log_failure("OpenRouter", e)
    [ { image_input: "unknown", source: "openrouter_models" }, OPENROUTER_FAILURE_TTL ]
  end

  def get_json(uri, headers: {})
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 2
    http.read_timeout = 3
    request = Net::HTTP::Get.new(uri)
    headers.each { |key, value| request[key] = value }
    response = http.request(request)
    raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  end

  def log_failure(provider, error)
    Rails.logger.warn("Image capability lookup failed for #{provider}: #{error.class}: #{error.message}")
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
