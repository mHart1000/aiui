require "test_helper"

class RerankerAdapters::LlamaAdapterTest < ActiveSupport::TestCase
  test "resolve_model_id prefers explicit constructor argument" do
    adapter = RerankerAdapters::LlamaAdapter.new(model: "my-explicit-reranker")
    with_env("RERANKER_MODEL" => "from-env") do
      adapter = RerankerAdapters::LlamaAdapter.new(model: "my-explicit-reranker")
      adapter.stub(:fetch_server_model_id, "from-server") do
        assert_equal "my-explicit-reranker", adapter.send(:resolve_model_id)
      end
    end
  end

  test "resolve_model_id falls back to RERANKER_MODEL env var" do
    with_env("RERANKER_MODEL" => "env-reranker") do
      adapter = RerankerAdapters::LlamaAdapter.new
      adapter.stub(:fetch_server_model_id, "server-reranker") do
        assert_equal "env-reranker", adapter.send(:resolve_model_id)
      end
    end
  end

  test "resolve_model_id falls back to /v1/models auto-detect" do
    with_env("RERANKER_MODEL" => nil) do
      adapter = RerankerAdapters::LlamaAdapter.new
      adapter.stub(:fetch_server_model_id, "auto-detected-reranker") do
        assert_equal "auto-detected-reranker", adapter.send(:resolve_model_id)
      end
    end
  end

  test "resolve_model_id raises when all sources are empty" do
    with_env("RERANKER_MODEL" => nil) do
      adapter = RerankerAdapters::LlamaAdapter.new
      adapter.stub(:fetch_server_model_id, nil) do
        assert_raises(RuntimeError, /could not determine reranker model/) do
          adapter.send(:resolve_model_id)
        end
      end
    end
  end

  test "rerank returns sorted results with index/score/model" do
    adapter = RerankerAdapters::LlamaAdapter.new(model: "test-reranker")
    stub_post(adapter, {
      "results" => [
        { "index" => 0, "relevance_score" => 0.1 },
        { "index" => 1, "relevance_score" => 0.9 },
        { "index" => 2, "relevance_score" => 0.5 }
      ]
    })

    results = adapter.rerank(query: "q", documents: [ "a", "b", "c" ])

    assert_equal [ 1, 2, 0 ], results.map { |r| r[:index] }
    assert_equal [ 0.9, 0.5, 0.1 ], results.map { |r| r[:score] }
    results.each { |r| assert_equal "test-reranker", r[:model] }
  end

  test "rerank handles nested document.relevance_score shape" do
    adapter = RerankerAdapters::LlamaAdapter.new(model: "test-reranker")
    stub_post(adapter, {
      "results" => [
        { "index" => 0, "document" => { "relevance_score" => 0.7 } },
        { "index" => 1, "document" => { "relevance_score" => 0.2 } }
      ]
    })

    results = adapter.rerank(query: "q", documents: [ "a", "b" ])
    assert_equal [ 0, 1 ], results.map { |r| r[:index] }
    assert_equal [ 0.7, 0.2 ], results.map { |r| r[:score] }
  end

  test "rerank returns empty array when documents are empty" do
    adapter = RerankerAdapters::LlamaAdapter.new(model: "test-reranker")
    assert_equal [], adapter.rerank(query: "q", documents: [])
    assert_equal [], adapter.rerank(query: "q", documents: nil)
  end

  test "rerank raises on malformed response" do
    adapter = RerankerAdapters::LlamaAdapter.new(model: "test-reranker")
    stub_post(adapter, { "no_results_key" => true })
    assert_raises(RuntimeError, /malformed response/) do
      adapter.rerank(query: "q", documents: [ "a" ])
    end
  end

  test "rerank raises on malformed result entry" do
    adapter = RerankerAdapters::LlamaAdapter.new(model: "test-reranker")
    stub_post(adapter, { "results" => [ { "index" => "not-an-int", "relevance_score" => 0.5 } ] })
    assert_raises(RuntimeError, /malformed result entry/) do
      adapter.rerank(query: "q", documents: [ "a" ])
    end
  end

  private

  def stub_post(adapter, body)
    adapter.define_singleton_method(:post_rerank) { |_query, _documents| body }
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
