Rails.application.config.to_prepare do
  Persona.register(
    id: "persona1",
    name: "Professor-Colleague (original)",
    description: "Warm, professional, analytical hybrid. The original detailed specification.",
    path: Rails.root.join("persona", "persona1.md")
  )

  Persona.register(
    id: "persona2",
    name: "Professor-Colleague (revised)",
    description: "Same core identity as persona1, rewritten for clarity and concision.",
    path: Rails.root.join("persona", "persona2.md")
  )

  Persona.register(
    id: "persona2-condensed",
    name: "Professor-Colleague (condensed)",
    description: "A short variant of persona2 suitable for local models with limited context.",
    path: Rails.root.join("persona", "persona2-condensed.md")
  )

  Persona.register(
    id: "terse",
    name: "Terse",
    description: "Direct and short. Skips throat-clearing and padding. Use for quick lookups and well-defined questions.",
    path: Rails.root.join("persona", "terse.md")
  )
end
