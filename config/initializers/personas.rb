Rails.application.config.to_prepare do
  Persona.register(
    id: "persona1",
    name: "Professor-Colleague",
    description: "Warm, professional, analytical hybrid — clarity of a professor, collaboration of a senior colleague.",
    full_path: Rails.root.join("persona", "persona1.md"),
    condensed_path: Rails.root.join("persona", "persona1-condensed.md")
  )
end
