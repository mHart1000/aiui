require "test_helper"
require Rails.root.join("db/migrate/20261004000000_rename_high_web_search_level_to_medium")

class ExpandedProfilesTest < ActiveSupport::TestCase
  test "high selector accepts its query allowance and passes the profile to research" do
    profile = WebResearch::Profile.for_level("high")
    service = ChatService.new(messages: [ { role: "user", content: "Research local inference" } ],
      model: "local-llama", use_persona: false, use_scaffolding: false,
      stream: false, max_tokens: nil, web_search_mode: "always", web_search_level: "high")
    queries = Array.new(profile[:max_queries]) { |i| "local inference topic #{i}" }
    selection = { tool_calls: [ { "function" => { "name" => "research_web", "arguments" => { "queries" => queries }.to_json } } ] }
    research = Object.new
    research.define_singleton_method(:call) { { evidence: "Evidence", metadata: { status: "complete" } } }
    adapter = service.instance_variable_get(:@adapter)
    adapter.stub(:chat, ->(**args) {
      assert_equal profile[:selector_max_tokens], args[:max_tokens]
      assert_equal queries.length, args[:tools].first.dig(:function, :parameters, :properties, :queries, :maxItems)
      selection
    }) do
      WebResearch::Service.stub(:new, ->(**args) {
        assert_equal queries, args[:request].queries
        assert_equal profile, args[:budgets]
        assert_equal profile[:web_evidence_chars], args[:max_evidence_chars]
        research
      }) { service.send(:perform_web_research) }
    end
    assert_equal profile[:max_tokens], service.instance_variable_get(:@max_tokens)
  end

  test "service configures larger extracts only for high" do
    body = Array.new(100) { |i| "Paragraph #{i}: " + "Local inference research. " * 6 }.join("\n\n")
    lengths = WebResearch::Profile::LEVELS.map do |level|
      profile = WebResearch::Profile.for_level(level)
      service = WebResearch::Service.new(request: nil, budgets: profile)
      result = service.instance_variable_get(:@fetcher).send(:extract_text, body, "text/plain")
      assert_operator result.text.length, :<=, profile[:page_max_text_chars]
      assert result.truncated
      result.text.length
    end
    assert_equal lengths[0], lengths[1]
    assert_operator lengths[2], :>, lengths[1]
  end

  test "migration preserves low and inheritance and renames existing high in both directions" do
    user = User.create!(email: "migration@example.com", password: "password123", web_search_level: "high")
    high = user.conversations.create!(web_search_level: "high")
    low = user.conversations.create!(web_search_level: "low")
    inherited = user.conversations.create!
    migration = RenameHighWebSearchLevelToMedium.new
    migration.suppress_messages { migration.up }
    assert_equal "medium", user.reload.web_search_level
    assert_equal "medium", high.reload.web_search_level
    assert_equal "low", low.reload.web_search_level
    assert_nil inherited.reload.web_search_level
    migration.suppress_messages { migration.down }
    assert_equal "high", user.reload.web_search_level
    assert_equal "high", high.reload.web_search_level
    assert_equal "low", low.reload.web_search_level
    assert_nil inherited.reload.web_search_level
  end
end
