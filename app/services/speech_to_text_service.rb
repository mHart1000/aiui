# frozen_string_literal: true

class SpeechToTextService
  # Transcribes an audio file using the specified adapter
  # @param audio_path [String] Absolute path to an audio file readable by the adapter
  # @param adapter [String, Symbol, nil] Which STT adapter to use (default: :whisper)
  # @return [String] Transcribed text
  def self.call(audio_path:, adapter: nil)
    adapter_instance = resolve_adapter(adapter)
    adapter_instance.transcribe(audio_path: audio_path)
  end

  # Checks if the STT backend is available
  # @param adapter [String, Symbol, nil] Which STT adapter to check
  # @return [Boolean] true if the adapter is available
  def self.available?(adapter: nil)
    adapter_instance = resolve_adapter(adapter)
    adapter_instance.available?
  end

  # Resolves adapter name to adapter instance
  # @param adapter [String, Symbol, nil] Adapter name
  # @return [SttAdapters::BaseAdapter] Adapter instance
  def self.resolve_adapter(adapter)
    case adapter&.to_s
    when "whisper", nil
      SttAdapters::WhisperAdapter.new
    else
      SttAdapters::WhisperAdapter.new
    end
  end
  private_class_method :resolve_adapter
end
