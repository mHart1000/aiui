module RerankerAdapters
  # Adapters return an Array of { index: Integer, score: Float, model: String }
  # from #rerank, sorted by score descending. `index` is the original position
  # in the `documents` array so callers can reorder their own objects without
  # the adapter needing to know their type.
  class BaseAdapter
    def rerank(query:, documents:)
      raise NotImplementedError, "#{self.class.name} must implement #rerank"
    end
  end
end
