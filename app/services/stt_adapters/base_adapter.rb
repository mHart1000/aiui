# frozen_string_literal: true

module SttAdapters
  class BaseAdapter
    # Transcribes an audio file and returns the recognized text
    # @param audio_path [String] Absolute path to an audio file readable by the adapter
    # @return [String] Transcribed text
    def transcribe(audio_path:)
      raise NotImplementedError, "#{self.class} must implement #transcribe"
    end

    # Checks if the STT backend is reachable and operational
    # @return [Boolean] true if the backend is available
    def available?
      raise NotImplementedError, "#{self.class} must implement #available?"
    end
  end
end
