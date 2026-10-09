module WebResearch
  # Budgets for a web-research level; LEVELS drives the UI, for_level picks one.
  class Profile
    DEFAULT_LEVEL = "low".freeze

    PROFILES = {
      "low" => {
        selector_max_tokens: 200,
        page_max_text_chars: 6_000,
        max_tokens: 16_000,
        max_pages: 4,
        max_fetch_attempts: 10,
        search_deadline_seconds: 5,
        research_deadline_seconds: 8,
        max_queries: 2,
        selector_max_messages: 4,
        selector_max_message_chars: 2_000,
        selector_max_transcript_chars: 3_000,
        rag_context_chars: 24_000,
        rag_context_chars_with_web: 12_000,
        web_evidence_chars: 23_500,
        web_evidence_chars_with_rag: 11_500,
        rag_hard_cap_chars: 24_000,
        rag_per_chunk_cap_chars: 2_000
      },
      "medium" => {
        selector_max_tokens: 200,
        page_max_text_chars: 6_000,
        max_tokens: 32_000,
        max_pages: 6,
        max_fetch_attempts: 20,
        search_deadline_seconds: 8,
        research_deadline_seconds: 15,
        max_queries: 3,
        selector_max_messages: 5,
        selector_max_message_chars: 3_000,
        selector_max_transcript_chars: 4_000,
        rag_context_chars: 48_000,
        rag_context_chars_with_web: 24_000,
        web_evidence_chars: 47_000,
        web_evidence_chars_with_rag: 23_000,
        rag_hard_cap_chars: 48_000,
        rag_per_chunk_cap_chars: 2_400
      },
      "high" => {
        selector_max_tokens: 800,
        page_max_text_chars: 12_000,
        max_tokens: 48_000,
        max_pages: 12,
        max_fetch_attempts: 40,
        search_deadline_seconds: 20,
        research_deadline_seconds: 40,
        max_queries: 4,
        selector_max_messages: 10,
        selector_max_message_chars: 6_000,
        selector_max_transcript_chars: 16_000,
        rag_context_chars: 120_000,
        rag_context_chars_with_web: 48_000,
        web_evidence_chars: 120_000,
        web_evidence_chars_with_rag: 72_000,
        rag_hard_cap_chars: 120_000,
        rag_per_chunk_cap_chars: 4_000
      }
    }.freeze

    LEVELS = PROFILES.keys.freeze

    def self.levels
      LEVELS
    end

    # Falls back to the default level for blank or unknown values.
    def self.for_level(level)
      PROFILES.fetch(level.to_s, PROFILES[DEFAULT_LEVEL])
    end
  end
end
