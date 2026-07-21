# frozen_string_literal: true

class TextToSpeechService
  DEFAULT_ADAPTER = "kokoro"

  # Synthesizes text to speech using the specified adapter
  # @param text [String] The text to synthesize
  # @param voice [String, nil] Voice identifier
  # @param speed [Float, nil] Playback speed multiplier
  # @param adapter [String, Symbol, nil] Which TTS adapter to use (default: ENV["TTS_ADAPTER"] or :kokoro)
  # @return [String] Raw audio bytes
  def self.call(text:, voice: nil, speed: nil, adapter: nil)
    adapter_instance = resolve_adapter(adapter)
    adapter_instance.synthesize(text: text, voice: voice, speed: speed)
  end

  # Streams synthesized audio, yielding chunks as they arrive
  # @param text [String] The text to synthesize
  # @param voice [String, nil] Voice identifier
  # @param speed [Float, nil] Playback speed multiplier
  # @param adapter [String, Symbol, nil] Which TTS adapter to use
  # @yield [String] Raw audio chunks
  def self.stream(text:, voice: nil, speed: nil, adapter: nil, &block)
    adapter_instance = resolve_adapter(adapter)
    label = adapter_instance.class.name.demodulize.sub(/Adapter\z/, "").downcase

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ttfb = nil
    result = adapter_instance.synthesize_stream(text: text, voice: voice, speed: speed) do |chunk|
      ttfb ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      block.call(chunk)
    end

    total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    # One latency line per stream: text size in, time to first audio chunk, total synth time.
    Rails.logger.info(
      "TTS stream: adapter=#{label} chars=#{text.to_s.length} " \
      "ttfb_ms=#{ttfb ? (ttfb * 1000).round : "nil"} total_ms=#{(total * 1000).round}"
    )
    result
  end

  # Whether the active adapter supports chunked streaming
  # @param adapter [String, Symbol, nil] Which TTS adapter to check
  # @return [Boolean]
  def self.streaming?(adapter: nil)
    resolve_adapter(adapter).streaming?
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
  # Defaults to ENV["TTS_ADAPTER"] (falling back to Kokoro) when no name is given
  # @param adapter [String, Symbol, nil] Adapter name
  # @return [TtsAdapters::BaseAdapter] Adapter instance
  def self.resolve_adapter(adapter)
    name = adapter&.to_s || ENV["TTS_ADAPTER"] || DEFAULT_ADAPTER

    case name.downcase
    when "kokoro"
      TtsAdapters::KokoroAdapter.new
    when "qwen3"
      TtsAdapters::Qwen3Adapter.new
    when "chatterbox"
      TtsAdapters::ChatterboxAdapter.new
    else
      Rails.logger.warn "Unknown TTS adapter #{name.inspect}, falling back to Kokoro"
      TtsAdapters::KokoroAdapter.new
    end
  end
  private_class_method :resolve_adapter
end
