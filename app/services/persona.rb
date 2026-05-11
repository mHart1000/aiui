require "digest"

class Persona
  REGISTRY = {}

  attr_reader :id, :name, :description, :full_path, :condensed_path

  def self.register(id:, name:, description:, full_path:, condensed_path: nil)
    REGISTRY[id.to_s] = new(
      id: id.to_s,
      name: name,
      description: description,
      full_path: full_path,
      condensed_path: condensed_path
    )
  end

  def self.find(id)
    REGISTRY[id.to_s]
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
  end

  def initialize(id:, name:, description:, full_path:, condensed_path:)
    @id = id
    @name = name
    @description = description
    @full_path = full_path
    @condensed_path = condensed_path
  end

  def load(variant)
    path = path_for(variant)
    content = read_cached(path)
    return nil unless content

    {
      content: content,
      version: Digest::SHA1.hexdigest(content)[0, 8],
      variant: actual_variant_for(variant)
    }
  end

  private

  def path_for(variant)
    if variant == :condensed && @condensed_path
      @condensed_path
    else
      @full_path
    end
  end

  def actual_variant_for(variant)
    variant == :condensed && @condensed_path ? :condensed : :full
  end

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
