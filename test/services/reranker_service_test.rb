require "test_helper"

class RerankerServiceTest < ActiveSupport::TestCase
  test "delegates to adapter and returns results" do
    fake = Class.new do
      def rerank(query:, documents:)
        documents.each_with_index.map { |_, i| { index: i, score: 1.0 - (i * 0.1), model: "fake" } }
      end
    end.new
    service = RerankerService.new
    service.instance_variable_set(:@adapter, fake)

    results = service.rerank(query: "q", documents: [ "a", "b", "c" ])
    assert_equal 3, results.length
    assert_equal [ 0, 1, 2 ], results.map { |r| r[:index] }
    results.each { |r| assert_equal "fake", r[:model] }
  end

  test "returns empty array when documents are empty" do
    fake = Class.new do
      def rerank(query:, documents:)
        raise "should not be called"
      end
    end.new
    service = RerankerService.new
    service.instance_variable_set(:@adapter, fake)

    assert_equal [], service.rerank(query: "q", documents: [])
    assert_equal [], service.rerank(query: "q", documents: nil)
  end

  test "raises when query is blank" do
    service = RerankerService.new
    assert_raises(ArgumentError, /query cannot be blank/) do
      service.rerank(query: "", documents: [ "a" ])
    end
    assert_raises(ArgumentError, /query cannot be blank/) do
      service.rerank(query: "   ", documents: [ "a" ])
    end
  end

  test "raises when adapter returns non-array" do
    fake = Class.new do
      def rerank(query:, documents:)
        "not an array"
      end
    end.new
    service = RerankerService.new
    service.instance_variable_set(:@adapter, fake)

    assert_raises(RuntimeError, /must return an Array/) do
      service.rerank(query: "q", documents: [ "a" ])
    end
  end

  test "raises when adapter returns malformed result entry" do
    fake = Class.new do
      def rerank(query:, documents:)
        [ { index: 0, score: 0.5, model: "" } ]
      end
    end.new
    service = RerankerService.new
    service.instance_variable_set(:@adapter, fake)

    assert_raises(RuntimeError, /non-empty model/) do
      service.rerank(query: "q", documents: [ "a" ])
    end
  end

  test "build_adapter raises on unknown adapter name" do
    assert_raises(ArgumentError, /Unknown reranker adapter/) do
      RerankerService.new(adapter_name: "mystery")
    end
  end
end
