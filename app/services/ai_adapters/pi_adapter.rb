require "open3"
require "json"

module AiAdapters
  class PiAdapter < BaseAdapter
    class Error < StandardError; end
    PROCESS_TERMINATION_GRACE_SECONDS = 2
    STDERR_BUFFER_LIMIT = 8192
    STDERR_DETAIL_LIMIT = 500
    STDERR_READ_CHUNK_SIZE = 4096

    def initialize(repo_path:, session_id:, model: nil, pi_bin: nil)
      super(model: "pi")
      @repo_path = repo_path
      @session_id = session_id
      @model = model
      @pi_bin = pi_bin || ENV.fetch("PI_BIN", "pi")
    end

    # Yields (chunk, :response) and (chunk, :repo_activity)
    # Returns { finish_reason:, tokens:, stats:, model_label:, pi_data: }
    # Raises PiAdapter::Error on failure
    def chat(messages:, stream: false, **_opts, &block)
      prompt = extract_prompt(messages)
      cmd = build_command(prompt)

      full_content = +""
      segment_breaks = []
      activities = []
      message_usages = []
      final_stop_reason = nil
      last_assistant_content = nil

      started_at = monotonic_now
      stdin = nil
      stdout = nil
      stderr = nil
      wait_thr = nil
      stderr_thread = nil

      begin
        stdin, stdout, stderr, wait_thr = Open3.popen3(
          { "HOME" => ENV["HOME"] },
          *cmd,
          chdir: @repo_path,
          pgroup: true
        )
        stdin.close
        stderr_thread = start_stderr_reader(stderr)

        buffer = ""
        while (line = stdout.gets)
          buffer += line
          while (line_end = buffer.index("\n"))
            json_line = buffer.slice!(0, line_end + 1).strip
            next if json_line.empty?

            event = JSON.parse(json_line)
            process_event(event, full_content: full_content, segment_breaks: segment_breaks,
                          activities: activities, message_usages: message_usages, &block)
            if event["type"] == "message_end" && event.dig("message", "role") == "assistant"
              final_stop_reason = event.dig("message", "stopReason")
              last_assistant_content = event["message"].fetch("errorMessage", nil) || extract_text_content(event["message"]["content"])
            end
          end
        end
        stderr_output = stderr_thread.value

        exit_status = wait_thr.value
        elapsed = monotonic_now - started_at

        # Check for no assistant messages produced
        if message_usages.empty? && full_content.empty?
          detail = stderr_tail(stderr_output) || "no stderr output"
          raise Error, "Pi produced no output (exit #{exit_status.exitstatus}): #{detail}"
        end

        # Check stop reason
        if final_stop_reason == "error"
          detail = last_assistant_content.presence || stderr_tail(stderr_output) || "no details"
          raise Error, "Pi reported an error: #{detail}"
        elsif final_stop_reason == "aborted"
          raise Error, "Pi was aborted"
        end

        # Check process exit (non-zero with some output is still suspicious)
        unless exit_status.success?
          detail = stderr_tail(stderr_output) || "no stderr output"
          raise Error, "Pi exited with code #{exit_status.exitstatus}: #{detail}"
        end

        tokens = aggregate_tokens(message_usages)
        stats = build_stats(tokens: tokens, elapsed: elapsed)

        pi_data = {
          activities: activities,
          segment_breaks: segment_breaks
        }

        {
          finish_reason: final_stop_reason || "stop",
          tokens: tokens,
          stats: stats,
          model_label: "Pi",
          pi_data: pi_data
        }
      ensure
        terminate_process_group(wait_thr) if wait_thr&.alive?
        close_io(stdin)
        close_io(stdout)
        close_io(stderr)
        cleanup_stderr_reader(stderr_thread)
      end
    end

    private

    def start_stderr_reader(stderr)
      Thread.new do
        buffer = +"".b
        begin
          loop do
            chunk = stderr.readpartial(STDERR_READ_CHUNK_SIZE)
            buffer << chunk.b
            if buffer.bytesize > STDERR_BUFFER_LIMIT
              buffer.slice!(0, buffer.bytesize - STDERR_BUFFER_LIMIT)
            end
          end
        rescue EOFError, IOError
          # Stream closed or reached EOF.
        end
        buffer.force_encoding("UTF-8").scrub.strip
      end
    end

    def cleanup_stderr_reader(thread)
      return unless thread

      unless thread.join(PROCESS_TERMINATION_GRACE_SECONDS)
        thread.kill
        thread.join
      end
    end

    def stderr_tail(stderr_output)
      return nil if stderr_output.blank?
      return stderr_output if stderr_output.length <= STDERR_DETAIL_LIMIT

      stderr_output[-STDERR_DETAIL_LIMIT..]
    end

    def terminate_process_group(wait_thr)
      process_group_id = -wait_thr.pid

      Process.kill("TERM", process_group_id)
      return if wait_thr.join(PROCESS_TERMINATION_GRACE_SECONDS)
      Process.kill("KILL", process_group_id)
      wait_thr.join
    rescue Errno::ESRCH
      # The process exited between the alive? check and the signal.
    rescue SystemCallError => e
      Rails.logger.error("Failed to terminate Pi process group #{wait_thr.pid}: #{e.full_message}")
    end

    def close_io(io)
      io&.close unless io&.closed?
    rescue IOError
      # The stream was already closed during process shutdown.
    end

    def build_command(prompt)
      cmd = [
        @pi_bin, "--mode", "json",
        "--session-id", @session_id,
        "--tools", "read,bash",
        "--thinking", "off"
      ]
      cmd += [ "--model", "llama.cpp/#{@model}" ] if @model
      cmd += [ "--", prompt ]
    end

    def extract_text_content(content)
      return content if content.is_a?(String)
      return nil unless content.is_a?(Array)
      content.select { |c| c["type"] == "text" }.pluck("text").join("\n").presence
    end

    def extract_prompt(messages)
      # Find the last user message and use its content as the prompt
      last_user = messages.reverse.find { |m| m[:role] == "user" }
      return "" unless last_user

      content = last_user[:content]
      if content.is_a?(Array)
        # Multimodal content: extract text parts only
        content.select { |part| part[:type] == "text" }.pluck(:text).join("\n")
      else
        content.to_s
      end
    end

    def process_event(event, full_content:, segment_breaks:, activities:, message_usages:, &block)
      case event["type"]
      when "message_update"
        handle_message_update(event, full_content: full_content, segment_breaks: segment_breaks,
                              activities: activities, &block)
      when "message_end"
        if event.dig("message", "role") == "assistant"
          usage = event.dig("message", "usage")
          message_usages << usage if usage
        end
      when "tool_execution_start"
        activity = activity_description(event["toolName"], event["args"])
        if activity.present?
          segment_breaks << full_content.length
          activities << activity
          block&.call(activity, :repo_activity)
        end
      end
    end

    def handle_message_update(event, full_content:, segment_breaks:, activities:, &block)
      ame = event["assistantMessageEvent"]
      return unless ame

      case ame["type"]
      when "text_delta"
        delta = ame["delta"].to_s
        return if delta.empty?

        full_content << delta
        block&.call(delta, :response)
      end
    end

    def activity_description(tool_name, args)
      args ||= {}
      case tool_name.to_s
      when "read"
        "Reading #{args["path"]}"
      when "bash"
        cmd = args["command"].to_s
        cmd = "#{cmd[0, 80]}..." if cmd.length > 80
        "Running: #{cmd}"
      else
        "#{tool_name.to_s.capitalize}"
      end
    end

    def aggregate_tokens(usages)
      return { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 } if usages.empty?

      completion = usages.sum { |u| u["output"] || 0 }
      prompt = usages.last&.dig("input") || 0
      total = usages.sum { |u| (u["input"] || 0) + (u["output"] || 0) }

      { prompt_tokens: prompt, completion_tokens: completion, total_tokens: total }
    end

    def build_stats(tokens:, elapsed:)
      elapsed_ms = (elapsed * 1000).round
      completion = tokens[:completion_tokens]
      tps = (completion.positive? && elapsed.positive?) ? (completion / elapsed) : nil

      {
        elapsed_ms: elapsed_ms,
        tokens_per_second: tps,
        tps_source: "computed"
      }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
