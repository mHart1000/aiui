require "test_helper"

class EmbeddingAdapters::LlamaAdapterTest < ActiveSupport::TestCase
  test "resolve_model_id prefers explicit constructor argument" do
    adapter = EmbeddingAdapters::LlamaAdapter.new(model: "my-explicit-model")
    ENV.stub(:[], ->(k) { k == "EMBEDDING_MODEL" ? "from-env" : nil }) do
      adapter.stub(:fetch_server_model_id, "from-server") do
        assert_equal "my-explicit-model", adapter.send(:resolve_model_id)
      end
    end
  end

  test "resolve_model_id falls back to EMBEDDING_MODEL env var" do
    adapter = EmbeddingAdapters::LlamaAdapter.new
    # @explicit_model is captured at init, so we set env inside init
    with_env("EMBEDDING_MODEL" => "env-model") do
      adapter = EmbeddingAdapters::LlamaAdapter.new
      adapter.stub(:fetch_server_model_id, "server-model") do
        assert_equal "env-model", adapter.send(:resolve_model_id)
      end
    end
  end

  test "resolve_model_id falls back to /v1/models auto-detect" do
    with_env("EMBEDDING_MODEL" => nil) do
      adapter = EmbeddingAdapters::LlamaAdapter.new
      adapter.stub(:fetch_server_model_id, "auto-detected-model") do
        assert_equal "auto-detected-model", adapter.send(:resolve_model_id)
      end
    end
  end

  test "resolve_model_id raises when all sources are empty" do
    with_env("EMBEDDING_MODEL" => nil) do
      adapter = EmbeddingAdapters::LlamaAdapter.new
      adapter.stub(:fetch_server_model_id, nil) do
        assert_raises(RuntimeError, /could not determine embedding model/) do
          adapter.send(:resolve_model_id)
        end
      end
    end
  end

  test "resolve_model_id caches the result across calls" do
    adapter = EmbeddingAdapters::LlamaAdapter.new(model: "cached-model")
    call_count = 0
    adapter.define_singleton_method(:fetch_server_model_id) do
      call_count += 1
      "should-not-be-called"
    end
    3.times { adapter.send(:resolve_model_id) }
    assert_equal 0, call_count, "fetch_server_model_id should not be called when explicit model provided"
  end

  private

  def with_env(vars)
    original = {}
    vars.each do |k, v|
      original[k] = ENV[k]
      ENV[k] = v
    end
    yield
  ensure
    original.each { |k, v| ENV[k] = v }
  end
end
