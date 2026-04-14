module EmbeddingAdapters
  # Adapters return { vector: Array<Float>, model: String } from #embed.
  # The model identifier is stored on every chunk so retrieval can filter
  # by embedding model and avoid cross-dimension comparisons.
  class BaseAdapter
    def embed(text:)
      raise NotImplementedError, "#{self.class.name} must implement #embed"
    end
  end
end
