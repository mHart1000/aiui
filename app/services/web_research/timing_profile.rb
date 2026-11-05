module WebResearch
  class TimingProfile
    DEFAULT_LEVEL = "low".freeze

    PROFILES = {
      "low" => { search_deadline_seconds: 5, research_deadline_seconds: 8 },
      "medium" => { search_deadline_seconds: 8, research_deadline_seconds: 15 },
      "high" => { search_deadline_seconds: 20, research_deadline_seconds: 40 }
    }.freeze

    LEVELS = PROFILES.keys.freeze

    def self.for_level(level)
      PROFILES.fetch(level.to_s, PROFILES[DEFAULT_LEVEL])
    end
  end
end
