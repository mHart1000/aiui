require "net/http"
require "json"
require "uri"

module AiAdapters
  class LlamaAdapter < BaseAdapter
    def chat(messages:, stream: false, max_tokens: nil, &block)
      base_url = ENV["LLAMA_API_URL"] || "http://host.docker.internal:8080/v1"
      uri = URI("#{base_url}/chat/completions")

      # Prepare payload compatible with OpenAI API
      payload = {
        model: @model, # e.g. "llama-3-8b"
        messages: messages,
        temperature: 0.7,
        stream: stream
      }
      payload[:max_tokens] = max_tokens if max_tokens
      # Ask llama.cpp to include a final usage chunk so we can log tokens/sec.
      payload[:stream_options] = { include_usage: true } if stream

      if stream
        perform_streaming_request(uri, payload, &block)
      else
        perform_blocking_request(uri, payload)
      end
    end

    private

    def perform_blocking_request(uri, payload)
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 120 # Local models can be slow

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer unused" # deeply mandated by some clients, often ignored by llama.cpp
      request.body = payload.to_json

      started_at = monotonic_now
      response = http.request(request)
      elapsed = monotonic_now - started_at

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error("Llama API Error: #{response.body}")
        raise "Llama API Error: #{response.code} - #{response.message}"
      end

      json = JSON.parse(response.body)
      tokens = extract_token_usage(json)
      stats = build_stats(tokens: tokens, timings: json["timings"], elapsed: elapsed, ttft_ms: nil)
      log_throughput(tokens: tokens, stats: stats)

      {
        content: json.dig("choices", 0, "message", "content"),
        tokens: tokens,
        stats: stats
      }
    end

    def perform_streaming_request(uri, payload)
      final_usage = nil
      final_timings = nil
      first_chunk_at = nil
      started_at = monotonic_now

      Net::HTTP.start(uri.host, uri.port) do |http|
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer unused"
        request.body = payload.to_json

        http.request(request) do |response|
          buffer = ""
          response.read_body do |chunk|
            buffer += chunk
            while (line_end = buffer.index("\n"))
              line = buffer.slice!(0, line_end + 1).strip
              next if line.empty?
              next if line == "data: [DONE]"

              if line.start_with?("data: ")
                json_str = line.sub("data: ", "")
                begin
                  json = JSON.parse(json_str)
                  # llama.cpp's final chunk (when stream_options.include_usage is set)
                  # has an empty choices array and a populated usage block. Capture
                  # it for throughput logging instead of yielding to the caller.
                  if json["usage"]
                    final_usage = json["usage"]
                    final_timings = json["timings"]
                  end
                  content = json.dig("choices", 0, "delta", "content")
                  if content
                    first_chunk_at ||= monotonic_now
                    yield content
                  end
                rescue JSON::ParserError
                  # Partial line or invalid JSON, ignore
                end
              end
            end
          end
        end
      end

      elapsed = monotonic_now - started_at
      ttft_ms = first_chunk_at ? ((first_chunk_at - started_at) * 1000).round : nil
      tokens = normalize_usage(final_usage)
      stats = build_stats(tokens: tokens, timings: final_timings, elapsed: elapsed, ttft_ms: ttft_ms)
      log_throughput(tokens: tokens, stats: stats)

      { tokens: tokens, stats: stats }
    end

    def extract_token_usage(response)
      normalize_usage(response["usage"])
    end

    def normalize_usage(usage)
      usage ||= {}
      {
        prompt_tokens: usage["prompt_tokens"] || 0,
        completion_tokens: usage["completion_tokens"] || 0,
        total_tokens: usage["total_tokens"] || 0
      }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def build_stats(tokens:, timings:, elapsed:, ttft_ms:)
      completion = tokens[:completion_tokens]
      server_tps = timings.is_a?(Hash) ? timings["predicted_per_second"] : nil
      prompt_ms = timings.is_a?(Hash) ? timings["prompt_ms"]&.round : nil

      tps_value, tps_source =
        if server_tps&.positive?
          [ server_tps.to_f, "server" ]
        elsif completion.positive? && elapsed.positive?
          [ completion / elapsed, "computed" ]
        else
          [ nil, "unknown" ]
        end

      app_overhead_ms = (ttft_ms && prompt_ms) ? (ttft_ms - prompt_ms) : nil

      {
        elapsed_ms: (elapsed * 1000).round,
        tokens_per_second: tps_value,
        tps_source: tps_source,
        ttft_ms: ttft_ms,
        prompt_ms: prompt_ms,
        app_overhead_ms: app_overhead_ms
      }
    end

    def log_throughput(tokens:, stats:)
      tps_str = stats[:tokens_per_second] ? "#{format('%.1f', stats[:tokens_per_second])} tok/s (source: #{stats[:tps_source]})" : "unknown"
      elapsed_str = format("%.2fs", stats[:elapsed_ms] / 1000.0)
      ttft_str = stats[:ttft_ms] ? "#{stats[:ttft_ms]}ms" : "n/a"
      prefill_str = stats[:prompt_ms] ? "#{stats[:prompt_ms]}ms" : "n/a"
      overhead_str = stats[:app_overhead_ms] ? "#{stats[:app_overhead_ms]}ms" : "n/a"

      Rails.logger.info(
        "LlamaAdapter [model=#{@model}]\n" \
        "  Tokens     — prompt: #{tokens[:prompt_tokens]}, completion: #{tokens[:completion_tokens]}, total: #{tokens[:total_tokens]}\n" \
        "  Latency    — end-to-end: #{elapsed_str}, time-to-first-token: #{ttft_str}, server prefill: #{prefill_str}, app overhead: #{overhead_str}\n" \
        "  Throughput — #{tps_str}"
      )
    end
  end
end
