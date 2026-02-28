module AiAdapters
  class BaseAdapter
    def initialize(model:)
      @model = model
    end

    def chat(messages:, stream: false, &block)
      raise NotImplementedError, "#{self.class.name} must implement #chat"
    end
  end
end
