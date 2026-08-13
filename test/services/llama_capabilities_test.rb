require "test_helper"

class LlamaCapabilitiesTest < ActiveSupport::TestCase
  def setup
    LlamaCapabilities.reset!
  end

  def teardown
    LlamaCapabilities.reset!
  end

  # Seed the memo directly rather than stubbing a private fetch.
  def with_props(props)
    LlamaCapabilities.instance_variable_set(:@props, props)
    LlamaCapabilities.instance_variable_set(:@fetched_at, Time.current)
    yield
  ensure
    LlamaCapabilities.reset!
  end

  test "reports vision when llama.cpp loaded a projector" do
    with_props({ "modalities" => { "vision" => true, "audio" => true } }) do
      assert LlamaCapabilities.vision?
    end
  end

  test "reports no vision when llama.cpp says the model is text-only" do
    with_props({ "modalities" => { "vision" => false } }) do
      assert_not LlamaCapabilities.vision?
    end
  end

  # Local-first: an unreachable server must not disable the one model that is
  # always present. See docs/image-attachments-spec.md §2.5.
  test "assumes vision when the server is unreachable" do
    with_props({}) do
      assert LlamaCapabilities.vision?
    end
  end

  test "assumes vision on a build with no modalities key" do
    with_props({ "model_path" => "./models/some.gguf" }) do
      assert LlamaCapabilities.vision?
    end
  end
end
