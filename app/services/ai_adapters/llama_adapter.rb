require "net/http"
require "json"
require "uri"

module AiAdapters
  class LlamaAdapter < BaseAdapter
    def initialize(model:, log_stats: true)
      super(model: model)
      @log_stats = log_stats
    end

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
        reasoning: json.dig("choices", 0, "message", "reasoning_content"),
        tokens: tokens,
        stats: stats
      }
    end

    def perform_streaming_request(uri, payload)
      final_usage = nil
      final_timings = nil
      # Stage timestamps, all relative to started_at, to pinpoint where latency
      # accrues: connect -> first raw byte (TTFB) -> first SSE event -> first
      # content delta (TTFT). A large TTFB means bytes are held upstream; a large
      # gap between TTFB and first content means bytes arrive but aren't content
      # yet (a long non-content preamble or parsing stall).
      connected_at = nil
      first_raw_at = nil
      first_event_at = nil
      first_reasoning_at = nil
      first_content_at = nil
      last_chunk_at = nil
      raw_chunks = 0
      reasoning_deltas = 0
      content_deltas = 0
      started_at = monotonic_now

      Net::HTTP.start(uri.host, uri.port) do |http|
        connected_at = monotonic_now
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer unused"
        request.body = payload.to_json

        http.request(request) do |response|
          buffer = ""
          response.read_body do |chunk|
            now = monotonic_now
            first_raw_at ||= now
            last_chunk_at = now
            raw_chunks += 1
            buffer += chunk
            while (line_end = buffer.index("\n"))
              line = buffer.slice!(0, line_end + 1).strip
              next if line.empty?
              next if line == "data: [DONE]"

              if line.start_with?("data: ")
                first_event_at ||= monotonic_now
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
                  # Reasoning models (e.g. Qwen3) stream chain-of-thought in
                  # reasoning_content, then switch to content for the answer.
                  # Tag each so the caller can route reasoning to a thinking UI.
                  reasoning = json.dig("choices", 0, "delta", "reasoning_content")
                  if reasoning
                    first_reasoning_at ||= monotonic_now
                    reasoning_deltas += 1
                    yield reasoning, :reasoning
                  end
                  content = json.dig("choices", 0, "delta", "content")
                  if content
                    first_content_at ||= monotonic_now
                    content_deltas += 1
                    yield content, :content
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
      ttft_ms = first_content_at ? ((first_content_at - started_at) * 1000).round : nil
      rel_ms = ->(t) { t ? ((t - started_at) * 1000).round : nil }
      stream_diag = {
        connect_ms: rel_ms.call(connected_at),
        ttfb_ms: rel_ms.call(first_raw_at),
        first_event_ms: rel_ms.call(first_event_at),
        first_reasoning_ms: rel_ms.call(first_reasoning_at),
        ttft_ms: ttft_ms,
        transport_gap_ms: (first_content_at && first_raw_at) ? ((first_content_at - first_raw_at) * 1000).round : nil,
        stream_span_ms: (last_chunk_at && first_raw_at) ? ((last_chunk_at - first_raw_at) * 1000).round : nil,
        raw_chunks: raw_chunks,
        reasoning_deltas: reasoning_deltas,
        content_deltas: content_deltas
      }
      tokens = normalize_usage(final_usage)
      stats = build_stats(tokens: tokens, timings: final_timings, elapsed: elapsed, ttft_ms: ttft_ms, stream_diag: stream_diag)
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

    def build_stats(tokens:, timings:, elapsed:, ttft_ms:, stream_diag: nil)
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
        app_overhead_ms: app_overhead_ms,
        stream_diag: stream_diag
      }
    end

    def log_throughput(tokens:, stats:)
      return unless @log_stats

      tps_str = stats[:tokens_per_second] ? "#{format('%.1f', stats[:tokens_per_second])} tok/s (source: #{stats[:tps_source]})" : "unknown"
      elapsed_str = format("%.2fs", stats[:elapsed_ms] / 1000.0)
      ttft_str = stats[:ttft_ms] ? "#{stats[:ttft_ms]}ms" : "n/a"
      prefill_str = stats[:prompt_ms] ? "#{stats[:prompt_ms]}ms" : "n/a"
      overhead_str = stats[:app_overhead_ms] ? "#{stats[:app_overhead_ms]}ms" : "n/a"

      message = +"LlamaAdapter [model=#{@model}]\n" \
        "  Tokens     — prompt: #{tokens[:prompt_tokens]}, completion: #{tokens[:completion_tokens]}, total: #{tokens[:total_tokens]}\n" \
        "  Latency    — end-to-end: #{elapsed_str}, time-to-first-token: #{ttft_str}, server prefill: #{prefill_str}, app overhead: #{overhead_str}\n" \
        "  Throughput — #{tps_str}"

      if (diag = stats[:stream_diag])
        avg_chunk = (diag[:raw_chunks].to_i.positive? && diag[:stream_span_ms]) ? format("%.1f", diag[:stream_span_ms].to_f / diag[:raw_chunks]) : nil
        message << "\n  Streaming  — connect: #{ms(diag[:connect_ms])}, first byte: #{ms(diag[:ttfb_ms])}, first SSE event: #{ms(diag[:first_event_ms])}, first reasoning: #{ms(diag[:first_reasoning_ms])}, first content: #{ms(diag[:ttft_ms])}"
        message << "\n             — raw→content gap: #{ms(diag[:transport_gap_ms])}, stream span: #{ms(diag[:stream_span_ms])}, raw chunks: #{diag[:raw_chunks]}, reasoning deltas: #{diag[:reasoning_deltas]}, content deltas: #{diag[:content_deltas]}#{avg_chunk ? ", avg #{avg_chunk}ms/chunk" : ''}"
      end

      Rails.logger.info(message)
    end

    def ms(value)
      value ? "#{value}ms" : "n/a"
    end
  end
end
