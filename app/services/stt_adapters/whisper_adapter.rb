# frozen_string_literal: true

require "open3"
require "securerandom"
require "fileutils"

module SttAdapters
  class WhisperAdapter < BaseAdapter
    WORK_DIR = Rails.root.join("tmp", "stt_work").freeze

    def transcribe(audio_path:)
      FileUtils.mkdir_p(WORK_DIR)
      base = WORK_DIR.join(SecureRandom.uuid).to_s
      wav_path = "#{base}.wav"
      out_prefix = base

      transcode_to_wav(audio_path, wav_path)
      run_whisper(wav_path, out_prefix)
      File.read("#{out_prefix}.txt").strip
    ensure
      File.delete(wav_path) if wav_path && File.exist?(wav_path)
      File.delete("#{out_prefix}.txt") if out_prefix && File.exist?("#{out_prefix}.txt")
    end

    def available?
      cli = ENV["WHISPER_CLI_PATH"]
      model = ENV["WHISPER_MODEL_PATH"]
      return false if cli.blank? || model.blank?
      File.executable?(cli) && File.readable?(model)
    end

    private

    def transcode_to_wav(input, output)
      _stdout, stderr, status = Open3.capture3(
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-i", input,
        "-ar", "16000", "-ac", "1", "-f", "wav",
        "-y", output
      )
      raise "ffmpeg transcode failed: #{stderr}" unless status.success?
    end

    def run_whisper(wav_path, out_prefix)
      _stdout, stderr, status = Open3.capture3(
        ENV.fetch("WHISPER_CLI_PATH"),
        "-m", ENV.fetch("WHISPER_MODEL_PATH"),
        "-f", wav_path,
        "-nt", "-np",
        "-otxt", "-of", out_prefix
      )
      raise "whisper-cli failed: #{stderr}" unless status.success?
    end
  end
end
