require "test_helper"

class EmbeddingAdapters::OpenaiAdapterTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :last_parameters

    def initialize(response)
      @response = response
    end

    def embeddings(parameters:)
      @last_parameters = parameters
      @response
    end
  end

  test "embed returns vector and configured model from a successful response" do
    fake = FakeClient.new({ "data" => [ { "embedding" => [ 0.1, 0.2, 0.3 ] } ] })
    adapter = EmbeddingAdapters::OpenaiAdapter.new(model: "text-embedding-3-small", client: fake)

    result = adapter.embed(text: "hello world")

    assert_equal [ 0.1, 0.2, 0.3 ], result[:vector]
    assert_equal "text-embedding-3-small", result[:model]
    assert_equal "text-embedding-3-small", fake.last_parameters[:model]
    assert_equal "hello world", fake.last_parameters[:input]
  end

  test "explicit constructor model wins over EMBEDDING_MODEL env var" do
    with_env("EMBEDDING_MODEL" => "text-embedding-3-large") do
      fake = FakeClient.new({ "data" => [ { "embedding" => [ 0.0 ] } ] })
      adapter = EmbeddingAdapters::OpenaiAdapter.new(model: "text-embedding-3-small", client: fake)
      assert_equal "text-embedding-3-small", adapter.embed(text: "x")[:model]
    end
  end

  test "EMBEDDING_MODEL env var is used when no explicit model is given" do
    with_env("EMBEDDING_MODEL" => "text-embedding-3-large") do
      fake = FakeClient.new({ "data" => [ { "embedding" => [ 0.0 ] } ] })
      adapter = EmbeddingAdapters::OpenaiAdapter.new(client: fake)
      assert_equal "text-embedding-3-large", adapter.embed(text: "x")[:model]
    end
  end

  test "falls back to DEFAULT_MODEL when nothing is configured" do
    with_env("EMBEDDING_MODEL" => nil) do
      fake = FakeClient.new({ "data" => [ { "embedding" => [ 0.0 ] } ] })
      adapter = EmbeddingAdapters::OpenaiAdapter.new(client: fake)
      assert_equal EmbeddingAdapters::OpenaiAdapter::DEFAULT_MODEL, adapter.embed(text: "x")[:model]
    end
  end

  test "raises on malformed response" do
    fake = FakeClient.new({ "data" => [] })
    adapter = EmbeddingAdapters::OpenaiAdapter.new(model: "m", client: fake)
    assert_raises(RuntimeError, /malformed response/) { adapter.embed(text: "hi") }
  end

  test "embed_batch returns one result per input, in order" do
    fake = FakeClient.new({ "data" => [ { "embedding" => [ 1.0 ] } ] })
    adapter = EmbeddingAdapters::OpenaiAdapter.new(model: "m", client: fake)
    results = adapter.embed_batch(texts: [ "a", "b", "c" ])
    assert_equal 3, results.length
    results.each { |r| assert_equal "m", r[:model] }
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
