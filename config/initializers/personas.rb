Rails.application.config.to_prepare do
  Persona.register(
    id: "persona1",
    name: "Professor-Colleague (original)",
    description: "Warm, professional, analytical hybrid. The original detailed specification.",
    full_path: Rails.root.join("persona", "persona1.md")
  )

  Persona.register(
    id: "persona2",
    name: "Professor-Colleague (revised)",
    description: "Same core identity as persona1, rewritten for clarity and concision. Has a condensed variant for local models.",
    full_path: Rails.root.join("persona", "persona2.md"),
    condensed_path: Rails.root.join("persona", "persona2-condensed.md")
  )
end
