# frozen_string_literal: true

module TtsAdapters
  class BaseAdapter
    # Synthesizes text to speech and returns raw audio bytes
    # @param text [String] The text to synthesize
    # @param voice [String, nil] The voice identifier to use
    # @param speed [Float, nil] The playback speed (0.5 - 2.0)
    # @return [String] Raw audio bytes in the format supported by the adapter
    def synthesize(text:, voice: nil, speed: nil)
      raise NotImplementedError, "#{self.class} must implement #synthesize"
    end

    # Returns array of available voice identifiers
    # @return [Array<String>] Array of voice IDs
    def voices
      raise NotImplementedError, "#{self.class} must implement #voices"
    end

    # Checks if the TTS backend is reachable and operational
    # @return [Boolean] true if the backend is available
    def available?
      raise NotImplementedError, "#{self.class} must implement #available?"
    end
  end
end
