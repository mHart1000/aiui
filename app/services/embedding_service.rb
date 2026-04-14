class EmbeddingService
  DEFAULT_ADAPTER = "llama".freeze

  # Returns { vector: Array<Float>, model: String }. The model identifier
  # is the source of truth for which embedder produced the vector, and must
  # be stored with every chunk so Rag::Retriever can filter by it and avoid
  # cross-dimension comparisons between models.
  def self.embed(text:)
    new.embed(text: text)
  end

  def initialize(adapter_name: nil)
    @adapter = build_adapter(adapter_name || ENV["EMBEDDING_ADAPTER"] || DEFAULT_ADAPTER)
  end

  def embed(text:)
    raise ArgumentError, "text cannot be blank" if text.to_s.strip.empty?
    result = @adapter.embed(text: text)
    unless result.is_a?(Hash) && result[:vector].is_a?(Array) && result[:model].is_a?(String) && !result[:model].empty?
      raise "EmbeddingService: adapter must return { vector:, model: } with non-empty model"
    end
    result
  end

  private

  def build_adapter(name)
    case name.to_s.downcase
    when "llama"
      EmbeddingAdapters::LlamaAdapter.new
    else
      raise ArgumentError, "Unknown embedding adapter: #{name}"
    end
  end
end
