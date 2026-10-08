module WebResearch
  class SearchPacer
    DEFAULT_INTERVAL_SECONDS = 3
    LOCK_POLL_SECONDS = 0.05
    class DeadlineExceeded < StandardError; end

    def initialize(interval: DEFAULT_INTERVAL_SECONDS, path: Rails.root.join("tmp", "web-search-pacing.lock"))
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
          previous = file.read
          delay = previous.empty? ? 0 : Float(previous) + @interval - Time.now.to_f
          wait(delay, deadline) if delay.positive?
          raise DeadlineExceeded, "Search deadline expired while waiting to send a query" if monotonic_now >= deadline

          file.rewind
          file.write(Time.now.to_f.to_s)
          file.truncate(file.pos)
          file.flush
          AuditLog.info("search_dispatched", sent_at: Time.current.iso8601(3), wait_ms: ((monotonic_now - started) * 1000).round)
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end

    private

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
