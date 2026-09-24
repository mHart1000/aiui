require "test_helper"
require "socket"

class WebResearch::HttpDeadlineTest < ActiveSupport::TestCase
  {
    "status line" => [ "", "H" ],
    "headers" => [ "HTTP/1.1 200 OK\r\n", "X-Slow: yes\r\n" ],
    "chunk framing" => [ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "1" ],
    "body" => [ "HTTP/1.1 200 OK\r\nContent-Length: 10000\r\n\r\n", "a" ]
  }.each do |stage, (prefix, fragment)|
    %i[page search].each do |client|
      test "#{client} deadline interrupts trickling #{stage} and closes the connection" do
        with_trickling_server(prefix, fragment) do |uri, server_thread|
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          deadline = started_at + 0.2

          if client == :page
            fetcher = WebResearch::PageFetcher.new
            # Route only this test's validated target to the loopback server.
            fetcher.stub(:validate_target!, [ uri, "127.0.0.1" ]) do
              error = assert_raises(WebResearch::PageFetcher::Error) do
                fetcher.fetch("http://public.example/article", deadline: deadline)
              end
              assert_equal "research deadline exceeded", error.message
            end
          else
            adapter = WebResearch::SearxngAdapter.new(base_url: uri.to_s)
            error = assert_raises(WebResearch::SearxngAdapter::Error) do
              adapter.search("example", deadline: deadline)
            end
            assert_equal "SearXNG response timed out", error.message
          end

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
          assert_operator elapsed, :<, 1, "the request outlived its shared deadline"
          assert server_thread.join(1), "the server did not observe the client disconnect"
          server_thread.value
        end
      end
    end
  end

  private

  def with_trickling_server(prefix, fragment)
    server = TCPServer.new("127.0.0.1", 0)
    server_thread = Thread.new do
      socket = server.accept
      content_length = 0
      while (line = socket.gets) && line != "\r\n"
        content_length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length:")
      end
      socket.read(content_length) if content_length.positive?
      socket.write(prefix)
      # Keep every read active, but never complete the response within the deadline.
      100.times do
        socket.write(fragment)
        sleep 0.02
      end
    rescue Errno::EPIPE, Errno::ECONNRESET
      # An interrupted request must close its socket.
    ensure
      socket&.close
    end
    server_thread.report_on_exception = false

    yield URI("http://127.0.0.1:#{server.addr[1]}/"), server_thread
  ensure
    server_thread&.kill
    server_thread&.join
    server&.close
  end
end
