# frozen_string_literal: true

class TextToSpeechService
  # Synthesizes text to speech using the specified adapter
  # @param text [String] The text to synthesize
  # @param voice [String, nil] Voice identifier
  # @param speed [Float, nil] Playback speed multiplier
  # @param adapter [String, Symbol, nil] Which TTS adapter to use (default: :kokoro)
  # @return [String] Raw audio bytes
  def self.call(text:, voice: nil, speed: nil, adapter: nil)
    adapter_instance = resolve_adapter(adapter)
    adapter_instance.synthesize(text: text, voice: voice, speed: speed)
  end

  # Checks if the TTS backend is available
  # @param adapter [String, Symbol, nil] Which TTS adapter to check
  # @return [Boolean] true if the adapter is available
  def self.available?(adapter: nil)
    adapter_instance = resolve_adapter(adapter)
    adapter_instance.available?
  end

  # Returns available voices for the adapter
  # @param adapter [String, Symbol, nil] Which TTS adapter to query
  # @return [Array<String>] Array of voice identifiers
  def self.voices(adapter: nil)
    adapter_instance = resolve_adapter(adapter)
    adapter_instance.voices
  end

  # Resolves adapter name to adapter instance
  # @param adapter [String, Symbol, nil] Adapter name
  # @return [TtsAdapters::BaseAdapter] Adapter instance
  def self.resolve_adapter(adapter)
    case adapter&.to_s
    when "kokoro", nil
      TtsAdapters::KokoroAdapter.new
    # Future adapters:
    # when "tada"
    #   TtsAdapters::TadaAdapter.new
    # when "elevenlabs"
    #   TtsAdapters::ElevenLabsAdapter.new
    else
      TtsAdapters::KokoroAdapter.new
    end
  end
  private_class_method :resolve_adapter
end
