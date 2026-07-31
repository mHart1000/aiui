require "digest"

class Persona
  REGISTRY = {}
  MODIFIERS = {}

  attr_reader :id, :name, :description, :path, :skip_modifiers

  def self.register(id:, name:, description:, path:, skip_modifiers: [])
    REGISTRY[id.to_s] = new(id: id.to_s, name: name, description: description, path: path, skip_modifiers: skip_modifiers)
  end

  # Mode constraints layered onto whichever persona is active. Not user-selectable.
  def self.register_modifier(id:, path:)
    MODIFIERS[id.to_s] = new(id: id.to_s, name: id.to_s, description: nil, path: path)
  end

  def self.find(id)
    REGISTRY[id.to_s]
  end

  def self.modifier(id)
    MODIFIERS[id.to_s]
  end

  def self.default
    REGISTRY["persona1"]
  end

  def self.all
    REGISTRY.values
  end

  def self.ids
    REGISTRY.keys
  end

  def self.reset!
    REGISTRY.clear
    MODIFIERS.clear
  end

  def initialize(id:, name:, description:, path:, skip_modifiers: [])
    @id = id
    @name = name
    @description = description
    @path = path
    @skip_modifiers = Array(skip_modifiers).map(&:to_s)
  end

  def content
    read_cached(@path)
  end

  # Modifiers append after the persona so their constraints win where the two conflict.
  def load(modifiers: [])
    base = content
    return nil unless base

    parts = [ base ]
    applied = []

    Array(modifiers).map(&:to_s).each do |mid|
      next if @skip_modifiers.include?(mid)

      text = self.class.modifier(mid)&.content
      if text.nil?
        Rails.logger.warn("Persona: modifier #{mid.inspect} unavailable, skipping")
        next
      end

      parts << text
      applied << mid
    end

    combined = parts.join("\n\n")
    {
      content: combined,
      version: Digest::SHA1.hexdigest(combined)[0, 8],
      modifiers: applied
    }
  end

  private

  def read_cached(path)
    return nil unless path && File.exist?(path)

    @cache ||= {}
    mtime = File.mtime(path)
    cached = @cache[path]
    return cached[:content] if cached && cached[:mtime] == mtime

    content = File.read(path)
    @cache[path] = { content: content, mtime: mtime }
    content
  rescue Errno::ENOENT, Errno::EACCES => e
    Rails.logger.warn("Persona: failed to read #{path}: #{e.class}: #{e.message}")
    nil
  end
end
