class RerankerService
  DEFAULT_ADAPTER = "llama".freeze

  # Returns [{ index:, score:, model: }, ...] sorted by score descending.
  # `index` refers to the caller's `documents` array so they can reorder
  # their own objects without the service needing to know the type.
  def self.rerank(query:, documents:)
    new.rerank(query: query, documents: documents)
  end

  def initialize(adapter_name: nil)
    @adapter = build_adapter(adapter_name || ENV["RERANKER_ADAPTER"] || DEFAULT_ADAPTER)
  end

  def rerank(query:, documents:)
    raise ArgumentError, "query cannot be blank" if query.to_s.strip.empty?
    return [] if documents.nil? || documents.empty?

    results = @adapter.rerank(query: query, documents: documents)
    unless results.is_a?(Array)
      raise "RerankerService: adapter must return an Array of results"
    end
    results.each do |r|
      unless r.is_a?(Hash) && r[:index].is_a?(Integer) && r[:score].is_a?(Numeric) && r[:model].is_a?(String) && !r[:model].empty?
        raise "RerankerService: each result must be { index:, score:, model: } with non-empty model"
      end
    end
    results
  end

  private

  def build_adapter(name)
    case name.to_s.downcase
    when "llama"
      RerankerAdapters::LlamaAdapter.new
    else
      raise ArgumentError, "Unknown reranker adapter: #{name}"
    end
  end
end
