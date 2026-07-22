#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Phase 1 sweep: measures the Qwen3 TTS server directly (no Rails in the path), using the
# same Net::HTTP streaming mechanism as Qwen3Adapter#synthesize_stream. Diff these numbers
# against the Rails "TTS stream:" log lines for the same input sizes -- the gap is
# Rails/controller/service overhead.
#
# Usage:  ruby tts_latency_sweep.rb
# Env:    QWEN3_TTS_URL (default http://localhost:8881), QWEN3_TTS_VOICE, REPS (default 3)

require "net/http"
require "json"
require "uri"

BASE_URL = ENV.fetch("QWEN3_TTS_URL", "http://localhost:8881")
VOICE = ENV["QWEN3_TTS_VOICE"] ||
        ENV["QWEN3_TTS_VOICES"].to_s.split(",").first&.strip ||
        "aiden"
REPS = Integer(ENV.fetch("REPS", "3"))
WAV_HEADER_BYTES = 44

# Sizes deliberately span the ~26-char threshold where a server-side flush floor would show up.
INPUTS = {
  "trivial" => "Hi.",
  "clause" => "It should be fine.",
  "sentence" => "The quick brown fox jumps over the lazy dog while the sun sets behind the hills.",
  "paragraph" => "The quick brown fox jumps over the lazy dog while the sun sets behind the hills. " \
                 "Nobody expected the weather to turn so quickly, but by evening the rain had started. " \
                 "We packed up the last of the gear and drove home in comfortable silence."
}.freeze

def synth(text)
  uri = URI("#{BASE_URL}/v1/audio/speech")
  req = Net::HTTP::Post.new(uri)
  req["Content-Type"] = "application/json"
  req.body = {
    model: "qwen3-tts", input: text, voice: VOICE, speed: 1.0, response_format: "wav"
  }.to_json

  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ttfa = nil
  bytes = 0
  header = +""
  byte_rate = nil

  Net::HTTP.start(uri.hostname, uri.port, open_timeout: 5, read_timeout: 120) do |http|
    http.request(req) do |res|
      raise "HTTP #{res.code} #{res.message}" unless res.is_a?(Net::HTTPSuccess)

      res.read_body do |chunk|
        bytes += chunk.bytesize
        if ttfa.nil? && bytes > WAV_HEADER_BYTES
          ttfa = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        end
        if byte_rate.nil?
          need = WAV_HEADER_BYTES - header.bytesize
          header << chunk.byteslice(0, need) if need.positive?
          byte_rate = header.byteslice(28, 4).unpack1("V") if header.bytesize >= WAV_HEADER_BYTES
        end
      end
    end
  end

  total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  audio = byte_rate&.positive? ? (bytes - WAV_HEADER_BYTES).to_f / byte_rate : nil

  {
    ttfa_ms: ttfa ? (ttfa * 1000).round : nil,
    total_ms: (total * 1000).round,
    audio_ms: audio ? (audio * 1000).round : nil,
    rtf: audio&.positive? ? (total / audio).round(2) : nil
  }
end

def median(vals)
  v = vals.compact.sort
  v.empty? ? nil : v[v.size / 2]
end

puts "Qwen3 TTS direct sweep -> #{BASE_URL} (voice=#{VOICE}, reps=#{REPS})"

begin
  print "warm-up... "
  synth("Warming up.")
  puts "ok"
rescue StandardError => e
  abort "warm-up failed: #{e.class}: #{e.message}\nIs the server up and the 8881 tunnel open?"
end

puts
printf("%-10s %6s %9s %9s %9s %6s\n", "input", "chars", "ttfa_ms", "total_ms", "audio_ms", "rtf")

INPUTS.each do |name, text|
  runs = REPS.times.map do
    synth(text)
  rescue StandardError => e
    warn "  #{name}: #{e.class}: #{e.message}"
    nil
  end.compact
  next if runs.empty?

  printf("%-10s %6d %9s %9s %9s %6s\n", name, text.length,
         median(runs.map { |r| r[:ttfa_ms] }),
         median(runs.map { |r| r[:total_ms] }),
         median(runs.map { |r| r[:audio_ms] }),
         median(runs.map { |r| r[:rtf] }))
end

puts
puts "Read it this way:"
puts "  ttfa_ms flat across sizes  -> floor is the server's internal flush granularity;"
puts "                                lever 2 (smaller first batch) is capped."
puts "  ttfa_ms falls with size    -> the floor is ours; lever 2 buys time-to-first-audio."
puts "  ttfa_ms here vs Rails log  -> the difference is Rails/controller/service overhead."
