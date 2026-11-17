require "test_helper"
require "stringio"

class AiAdapters::PiAdapterTest < ActiveSupport::TestCase
  test "extracts prompt from last user message" do
    adapter = AiAdapters::PiAdapter.new(repo_path: "/tmp", session_id: "123")
    prompt = adapter.send(:extract_prompt, [
      { role: "user", content: "earlier question" },
      { role: "assistant", content: "earlier answer" },
      { role: "user", content: "how does auth work?" }
    ])
    assert_equal "how does auth work?", prompt
  end

  test "extracts text from multimodal content" do
    adapter = AiAdapters::PiAdapter.new(repo_path: "/tmp", session_id: "123")
    prompt = adapter.send(:extract_prompt, [
      { role: "user", content: [
        { type: "text", text: "what is this?" },
        { type: "image_url", image_url: { url: "data:..." } }
      ] }
    ])
    assert_equal "what is this?", prompt
  end

  test "builds correct command" do
    adapter = AiAdapters::PiAdapter.new(repo_path: "/tmp", session_id: "conv-42")
    cmd = adapter.send(:build_command, "hello world")
    assert_equal [
      "pi", "--mode", "json",
      "--session-id", "conv-42",
      "--tools", "read,bash",
      "--thinking", "off",
      "--", "hello world"
    ], cmd
  end

  test "respects PI_BIN environment variable" do
    with_modified_env("PI_BIN", "/usr/local/bin/pi") do
      adapter = AiAdapters::PiAdapter.new(repo_path: "/tmp", session_id: "123")
      cmd = adapter.send(:build_command, "test")
      assert_equal "/usr/local/bin/pi", cmd.first
    end
  end

  test "streams response text and activity events" do
    events = [
      { "type" => "session", "id" => "test" },
      { "type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta", "delta" => "Let me check " } },
      { "type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta", "delta" => "the auth file." } },
      { "type" => "tool_execution_start", "toolCallId" => "call_1", "toolName" => "read", "args" => { "path" => "app/auth.rb" } },
      { "type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta", "delta" => "The auth flow uses JWT." } },
      { "type" => "message_end", "message" => { "role" => "assistant", "stopReason" => "stop", "usage" => { "input" => 100, "output" => 50 } } },
      { "type" => "agent_settled" }
    ]
    stream_jsonl = events.map { |e| e.to_json }.join("\n") + "\n"

    received = []
    stub_process(stream_jsonl, exit_status: 0) do
      adapter = AiAdapters::PiAdapter.new(repo_path: "/tmp", session_id: "123")
      result = adapter.chat(messages: [ { role: "user", content: "how does auth work?" } ]) do |chunk, phase|
        received << [ phase, chunk ]
      end

      # Check streamed events
      assert_equal :response, received[0][0]
      assert_equal "Let me check ", received[0][1]
      assert_equal :response, received[1][0]
      assert_equal "the auth file.", received[1][1]
      assert_equal :repo_activity, received[2][0]
      assert_equal "Reading app/auth.rb", received[2][1]
      assert_equal :response, received[3][0]
      assert_equal "The auth flow uses JWT.", received[3][1]

      # Check result
      assert_equal "stop", result[:finish_reason]
      assert_equal "Pi", result[:model_label]
      assert_equal 50, result[:tokens][:completion_tokens]
      assert_equal 100, result[:tokens][:prompt_tokens]

      # Check pi_data
      assert_equal [ "Reading app/auth.rb" ], result[:pi_data][:activities]
      # "Let me check " (13) + "the auth file." (14) = 27
      assert_equal [ 27 ], result[:pi_data][:segment_breaks]
    end
  end

  test "aggregates tokens across multiple assistant messages" do
    events = [
      { "type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta", "delta" => "First" } },
      { "type" => "message_end", "message" => { "role" => "assistant", "stopReason" => "stop", "usage" => { "input" => 100, "output" => 20 } } },
      { "type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta", "delta" => "Second" } },
      { "type" => "message_end", "message" => { "role" => "assistant", "stopReason" => "stop", "usage" => { "input" => 150, "output" => 30 } } },
      { "type" => "agent_settled" }
    ]
    stream_jsonl = events.map { |e| e.to_json }.join("\n") + "\n"

    stub_process(stream_jsonl, exit_status: 0) do
      adapter = AiAdapters::PiAdapter.new(repo_path: "/tmp", session_id: "123")
      result = adapter.chat(messages: [ { role: "user", content: "test" } ])

      assert_equal 50, result[:tokens][:completion_tokens] # 20 + 30
      assert_equal 150, result[:tokens][:prompt_tokens] # last message input
      assert_equal 300, result[:tokens][:total_tokens] # (100+20) + (150+30)
    end
  end

  test "raises on stopReason error" do
    events = [
      { "type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta", "delta" => "partial" } },
      { "type" => "message_end", "message" => { "role" => "assistant", "stopReason" => "error", "usage" => { "input" => 50, "output" => 10 } } },
      { "type" => "agent_settled" }
    ]
    stream_jsonl = events.map { |e| e.to_json }.join("\n") + "\n"

    stub_process(stream_jsonl, exit_status: 0) do
      adapter = AiAdapters::PiAdapter.new(repo_path: "/tmp", session_id: "123")
      assert_raises(AiAdapters::PiAdapter::Error) do
        adapter.chat(messages: [ { role: "user", content: "test" } ])
      end
    end
  end

  test "raises on non-zero exit" do
    events = [
      { "type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta", "delta" => "some text" } },
      { "type" => "message_end", "message" => { "role" => "assistant", "stopReason" => "stop", "usage" => { "input" => 10, "output" => 5 } } },
      { "type" => "agent_settled" }
    ]
    stream_jsonl = events.map { |e| e.to_json }.join("\n") + "\n"

    stub_process(stream_jsonl, exit_status: 1, stderr: "something went wrong") do
      adapter = AiAdapters::PiAdapter.new(repo_path: "/tmp", session_id: "123")
      error = assert_raises(AiAdapters::PiAdapter::Error) do
        adapter.chat(messages: [ { role: "user", content: "test" } ])
      end
      assert_match(/exit.*code.*1/, error.message)
    end
  end

  test "raises when no output produced" do
    stream_jsonl = "{\"type\":\"session\",\"id\":\"test\"}\n"

    stub_process(stream_jsonl, exit_status: 0) do
      adapter = AiAdapters::PiAdapter.new(repo_path: "/tmp", session_id: "123")
      assert_raises(AiAdapters::PiAdapter::Error) do
        adapter.chat(messages: [ { role: "user", content: "test" } ])
      end
    end
  end

  test "activity description for bash tool truncates long commands" do
    adapter = AiAdapters::PiAdapter.new(repo_path: "/tmp", session_id: "123")
    long_cmd = "grep -rn --include='*.rb' 'very_long_search_pattern_that_goes_well_beyond_eighty_characters_here' app/"
    assert long_cmd.length > 80, "test command must be longer than 80 chars"
    desc = adapter.send(:activity_description, "bash", { "command" => long_cmd })
    assert_equal "Running: #{long_cmd[0, 80]}...", desc
  end

  test "segment breaks track character offsets" do
    events = [
      { "type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta", "delta" => "Hello " } },
      { "type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta", "delta" => "world" } },
      { "type" => "tool_execution_start", "toolCallId" => "call_1", "toolName" => "read", "args" => { "path" => "file.rb" } },
      { "type" => "message_update", "assistantMessageEvent" => { "type" => "text_delta", "delta" => "Answer here" } },
      { "type" => "message_end", "message" => { "role" => "assistant", "stopReason" => "stop", "usage" => { "input" => 10, "output" => 5 } } },
      { "type" => "agent_settled" }
    ]
    stream_jsonl = events.map { |e| e.to_json }.join("\n") + "\n"

    stub_process(stream_jsonl, exit_status: 0) do
      adapter = AiAdapters::PiAdapter.new(repo_path: "/tmp", session_id: "123")
      result = adapter.chat(messages: [ { role: "user", content: "test" } ])

      # "Hello world" is 11 chars, so break at 11
      assert_equal [ 11 ], result[:pi_data][:segment_breaks]
    end
  end

  private

  class FakeStatus
    def initialize(code)
      @code = code
    end

    def success?
      @code == 0
    end

    def exitstatus
      @code
    end
  end

  def stub_process(stdout_string, exit_status:, stderr: "")
    fake_stdout = StringIO.new(stdout_string)
    fake_stderr = StringIO.new(stderr)
    fake_wait_thr = Object.new
    fake_wait_thr.define_singleton_method(:value) { FakeStatus.new(exit_status) }

    fake_stdin = StringIO.new
    Open3.stub(:popen3, ->(*_args, **_kwargs) { [ fake_stdin, fake_stdout, fake_stderr, fake_wait_thr ] }) do
      yield
    end
  end

  def with_modified_env(key, value)
    original = ENV[key]
    ENV[key] = value
    yield
  ensure
    ENV[key] = original
  end
end
