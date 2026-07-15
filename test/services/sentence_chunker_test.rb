require "test_helper"

class SentenceChunkerTest < ActiveSupport::TestCase
  setup do
    @chunker = SentenceChunker.new
  end

  test "emits a sentence once its terminator arrives across feeds" do
    assert_equal [], @chunker.feed("Hello wor")
    assert_equal [ "Hello world." ], @chunker.feed("ld. And")
    assert_equal [ "And more." ], @chunker.feed(" more.")
  end

  test "splits multiple sentences in one feed" do
    assert_equal [ "One.", "Two!", "Three?" ], @chunker.feed("One. Two! Three?")
  end

  test "handles single-character feeds like the dev echo stream" do
    sentences = "Hi there. Bye.".chars.flat_map { |c| @chunker.feed(c) }
    assert_equal [ "Hi there.", "Bye." ], sentences
    assert_nil @chunker.flush
  end

  test "emits a bullet line whole once its newline arrives" do
    assert_equal [], @chunker.feed("* first bullet point")
    assert_equal [ "first bullet point" ], @chunker.feed("\n")
  end

  test "numbered bullets are emitted whole" do
    # strip_markdown removes [-*+•] markers but not numeric ones, as in the browser
    assert_equal [ "1. Buy some milk" ], @chunker.feed("1. Buy some milk\n")
  end

  test "short bullets fall through to the punctuation split path" do
    assert_equal [ "hi" ], @chunker.feed("* hi\n")
  end

  test "code-like bullet lines fall through to the split path unfiltered" do
    # Mirrors the browser's asymmetry: only the bullet branch checks code_or_url?
    assert_equal [ "x = { a: 1, b: 2 }" ], @chunker.feed("- x = { a: 1, b: 2 }\n")
  end

  test "code-like partial-line sentences are skipped" do
    assert_equal [], @chunker.feed("x = [1, 2, 3];* 4. And")
    assert_equal [ "And then some words." ], @chunker.feed(" then some words.")
  end

  test "strips markdown from emitted sentences" do
    assert_equal [ "This is bold and a link." ],
      @chunker.feed("This is **bold** and [a link](/docs).")
  end

  test "em dashes become pauses" do
    assert_equal [ "Wait. really." ], @chunker.feed("Wait — really.")
  end

  test "heading markers are stripped" do
    assert_equal [ "Big Title" ], @chunker.feed("## Big Title\n")
  end

  test "sentences that strip to nothing are dropped" do
    assert_equal [], @chunker.feed("***\n")
  end

  test "blank lines are skipped" do
    assert_equal [], @chunker.feed("\n\n\n")
  end

  test "drops a fence spanning multiple feeds" do
    assert_equal [ "Look:" ], @chunker.feed("Look:\n```rub")
    assert_equal [], @chunker.feed("y\nputs 'hi'\n```")
    assert_equal [ "Done." ], @chunker.feed(" Done.")
  end

  test "handles a fence marker split across feeds" do
    assert_equal [ "Text before." ], @chunker.feed("Text before.``")
    assert_equal [], @chunker.feed("`hidden``")
    assert_equal [ "After." ], @chunker.feed("` After.")
  end

  test "flush returns the remainder as one sentence" do
    assert_equal [ "First." ], @chunker.feed("First. second half")
    assert_equal "second half", @chunker.flush
    assert_nil @chunker.flush
  end

  test "flush skips URLs" do
    assert_equal [], @chunker.feed("https://localhost:8880/foo")
    assert_nil @chunker.flush
  end

  test "flush includes a carried partial backtick that never became a fence" do
    assert_equal [], @chunker.feed("tick `")
    assert_equal "tick", @chunker.flush
  end
end
