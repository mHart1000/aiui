require "json"

module WebResearch
  class SearchPacer
    DEFAULT_INTERVAL_SECONDS = 3
    LOCK_POLL_SECONDS = 0.05
    FAILURE_COOLDOWN_SECONDS = 180
    class DeadlineExceeded < StandardError; end

    def initialize(interval: DEFAULT_INTERVAL_SECONDS, path: Rails.root.join("tmp", "web-search-pacing-#{Rails.env}.lock"))
      @interval = Float(interval)
      raise ArgumentError, "search interval must be finite and nonnegative" unless @interval.finite? && @interval >= 0
      @path = path
    end

    def call(deadline:)
      started = monotonic_now
      File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
        begin
          until file.flock(File::LOCK_EX | File::LOCK_NB)
            wait(LOCK_POLL_SECONDS, deadline)
          end
          state = read_state(file)
          delay = state.fetch("last_started_at", 0) + @interval - Time.now.to_f
          wait(delay, deadline) if delay.positive?
          raise DeadlineExceeded, "Search deadline expired while waiting to send a query" if monotonic_now >= deadline

          state["last_started_at"] = Time.now.to_f
          cooldowns = state["engines"] ||= {}
          cooldowns.delete_if { |_engine, data| data.fetch("retry_at") <= Time.now.to_f }
          write_state(file, state)
          AuditLog.info("search_dispatched", sent_at: Time.current.iso8601(3), wait_ms: ((monotonic_now - started) * 1000).round)
          response = yield cooldowns
          if response.respond_to?(:engine_failures)
            response.engine_failures.each do |engine, reason|
              next if cooldowns.key?(engine)
              retry_at = Time.now.to_f + FAILURE_COOLDOWN_SECONDS
              cooldowns[engine] = { "retry_at" => retry_at, "reason" => reason }
              AuditLog.warn("search_engine_cooldown_started", engine: engine, reason: reason,
                upstream_suspended: reason.start_with?("Suspended:"), retry_at: Time.at(retry_at).utc.iso8601)
            end
            write_state(file, state)
          end
          response
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end

    private

    def read_state(file)
      raw = file.read
      return {} if raw.empty?
      state = JSON.parse(raw)
      # Accept the scalar timestamp written by the original pacing implementation.
      state.is_a?(Numeric) ? { "last_started_at" => state } : state
    end

    def write_state(file, state)
      file.rewind
      file.write(JSON.generate(state))
      file.truncate(file.pos)
      file.flush
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def wait(seconds, deadline)
      remaining = deadline - monotonic_now
      if remaining <= 0 || seconds >= remaining
        raise DeadlineExceeded, "Search deadline cannot accommodate the pacing wait"
      end
      sleep seconds
    end
  end
end
