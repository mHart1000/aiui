require "test_helper"
require "tmpdir"

class WebResearch::SearchPacerTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir
    @path = File.join(@directory, "pacing.lock")
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  test "separate processes share the interval between starts" do
    interval = 0.1
    first = nil
    pacer(interval).call(deadline: now + 2) { first = Time.now.to_f }
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      pacer(interval).call(deadline: now + 2) { writer.write(Time.now.to_f.to_s) }
      writer.close
      exit! 0
    end
    writer.close
    second = Float(reader.read)
    Process.wait(pid)
    assert_operator second - first, :>=, interval - 0.005
  ensure
    reader&.close
    writer&.close unless writer&.closed?
  end

  test "a waiter expires without dispatch while another query holds the lock" do
    entered = Queue.new
    release = Queue.new
    thread = Thread.new do
      pacer(0).call(deadline: now + 2) do
        entered << true
        release.pop
      end
    end
    entered.pop
    assert_raises(WebResearch::SearchPacer::DeadlineExceeded) do
      pacer(0).call(deadline: now + 0.08) { flunk "overlapping query dispatched" }
    end
  ensure
    release << true
    thread&.join
  end

  test "a pacing wait that cannot fit leaves timestamp unchanged" do
    pacer(1).call(deadline: now + 2) { nil }
    timestamp = File.read(@path)
    assert_raises(WebResearch::SearchPacer::DeadlineExceeded) do
      pacer(1).call(deadline: now + 0.05) { flunk "expired query dispatched" }
    end
    assert_equal timestamp, File.read(@path)
  end

  test "failed queries release the lock but retain their start time" do
    assert_raises(IOError) do
      pacer(0).call(deadline: now + 2) { raise IOError, "request failed" }
    end
    assert_not_empty File.read(@path)
    result = pacer(0).call(deadline: now + 2) { :sent }
    assert_equal :sent, result
  end

  test "partial failures persist per engine across processes without extending on skips" do
    response = WebResearch::SearxngAdapter::SearchResults.new([ { url: "https://example.com" } ], engine_failures: [ [ "brave", "CAPTCHA" ] ])
    pacer(0).call(deadline: now + 2) { response }
    original = JSON.parse(File.read(@path)).fetch("engines")
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      pacer(0).call(deadline: now + 2) do |cooldowns|
        writer.write(JSON.generate(cooldowns))
        []
      end
      writer.close
      exit! 0
    end
    writer.close
    assert_equal original, JSON.parse(reader.read)
    Process.wait(pid)
    assert_equal original, JSON.parse(File.read(@path)).fetch("engines")
  ensure
    reader&.close
    writer&.close unless writer&.closed?
  end

  test "engine cooldowns expire independently and a failed trial renews only that engine" do
    freeze_time do
      pacer(0).call(deadline: now + 2) { failed_response }
      travel 10
      pacer(0).call(deadline: now + 2) do |cooldowns|
        assert_equal [ "brave" ], cooldowns.keys
        WebResearch::SearxngAdapter::SearchResults.new([], engine_failures: [ [ "duckduckgo", "CAPTCHA" ] ])
      end
      travel WebResearch::SearchPacer::FAILURE_COOLDOWN_SECONDS - 10
      pacer(0).call(deadline: now + 2) do |cooldowns|
        assert_equal [ "duckduckgo" ], cooldowns.keys
        failed_response
      end
      travel 11
      pacer(0).call(deadline: now + 2) do |cooldowns|
        assert_equal [ "brave" ], cooldowns.keys
        []
      end
    end
  end

  test "empty responses without diagnostics do not start a cooldown" do
    pacer(0).call(deadline: now + 2) do |cooldowns|
      assert_empty cooldowns
      WebResearch::SearxngAdapter::SearchResults.new([], engine_failures: [])
    end
    pacer(0).call(deadline: now + 2) { |cooldowns| assert_empty cooldowns }
  end

  test "a queued caller sees the first query's engine failures" do
    entered = Queue.new
    release = Queue.new
    thread = Thread.new do
      pacer(0).call(deadline: now + 2) do
        entered << true
        release.pop
        failed_response
      end
    end
    entered.pop
    waiter = Thread.new do
      pacer(0).call(deadline: now + 2) { |cooldowns| cooldowns.keys }
    end
    release << true
    thread.value
    assert_equal [ "brave" ], waiter.value
  ensure
    release << true
    thread&.join
    waiter&.join
  end

  test "reads original scalar pacing timestamps" do
    File.write(@path, Time.now.to_f.to_s)
    assert_raises(WebResearch::SearchPacer::DeadlineExceeded) do
      pacer(1).call(deadline: now + 0.01) { flunk "spacing skipped" }
    end
  end

  private

  def failed_response
    WebResearch::SearxngAdapter::SearchResults.new([], engine_failures: [ [ "brave", "too many requests" ] ])
  end

  def pacer(interval)
    WebResearch::SearchPacer.new(interval: interval, path: @path)
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
