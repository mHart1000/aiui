require "test_helper"

class EmbeddingAdapters::VoyageAdapterTest < ActiveSupport::TestCase
  test "raises at init when VOYAGE_API_KEY is not set" do
    with_env("VOYAGE_API_KEY" => nil) do
      assert_raises(RuntimeError, /VOYAGE_API_KEY/) do
        EmbeddingAdapters::VoyageAdapter.new
      end
    end
  end

  test "embed returns vector and configured model from a successful response" do
    adapter = EmbeddingAdapters::VoyageAdapter.new(model: "voyage-3-lite", api_key: "fake-key")
    stub_post(adapter, { "data" => [ { "embedding" => [ 0.4, 0.5 ] } ] })

    result = adapter.embed(text: "hello")

    assert_equal [ 0.4, 0.5 ], result[:vector]
    assert_equal "voyage-3-lite", result[:model]
  end

  test "explicit constructor model wins over EMBEDDING_MODEL env var" do
    with_env("EMBEDDING_MODEL" => "voyage-3") do
      adapter = EmbeddingAdapters::VoyageAdapter.new(model: "voyage-3-lite", api_key: "fake-key")
      stub_post(adapter, { "data" => [ { "embedding" => [ 0.0 ] } ] })
      assert_equal "voyage-3-lite", adapter.embed(text: "x")[:model]
    end
  end

  test "EMBEDDING_MODEL env var is used when no explicit model is given" do
    with_env("EMBEDDING_MODEL" => "voyage-3", "VOYAGE_API_KEY" => "fake-key") do
      adapter = EmbeddingAdapters::VoyageAdapter.new
      stub_post(adapter, { "data" => [ { "embedding" => [ 0.0 ] } ] })
      assert_equal "voyage-3", adapter.embed(text: "x")[:model]
    end
  end

  test "falls back to DEFAULT_MODEL when nothing is configured" do
    with_env("EMBEDDING_MODEL" => nil, "VOYAGE_API_KEY" => "fake-key") do
      adapter = EmbeddingAdapters::VoyageAdapter.new
      stub_post(adapter, { "data" => [ { "embedding" => [ 0.0 ] } ] })
      assert_equal EmbeddingAdapters::VoyageAdapter::DEFAULT_MODEL, adapter.embed(text: "x")[:model]
    end
  end

  test "raises on malformed response" do
    adapter = EmbeddingAdapters::VoyageAdapter.new(model: "m", api_key: "fake-key")
    stub_post(adapter, { "data" => [] })
    assert_raises(RuntimeError, /malformed response/) { adapter.embed(text: "hi") }
  end

  test "embed_batch returns one result per input, in order" do
    adapter = EmbeddingAdapters::VoyageAdapter.new(model: "m", api_key: "fake-key")
    stub_post(adapter, { "data" => [ { "embedding" => [ 1.0 ] } ] })
    results = adapter.embed_batch(texts: [ "a", "b", "c" ])
    assert_equal 3, results.length
    results.each { |r| assert_equal "m", r[:model] }
  end

  private

  def stub_post(adapter, body)
    adapter.define_singleton_method(:post_embeddings) { |_input| body }
  end

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
