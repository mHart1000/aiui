module EmbeddingAdapters
  # Adapters return { vector: Array<Float>, model: String } from #embed, and
  # an Array of those hashes (positionally aligned to the input) from
  # #embed_batch. The model identifier is stored on every chunk so retrieval
  # can filter by embedding model and avoid cross-dimension comparisons.
  class BaseAdapter
    def embed(text:)
      raise NotImplementedError, "#{self.class.name} must implement #embed"
    end

    def embed_batch(texts:)
      raise NotImplementedError, "#{self.class.name} must implement #embed_batch"
    end
  end
end
