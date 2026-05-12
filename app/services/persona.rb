require "digest"

class Persona
  REGISTRY = {}

  attr_reader :id, :name, :description, :path

  def self.register(id:, name:, description:, path:)
    REGISTRY[id.to_s] = new(id: id.to_s, name: name, description: description, path: path)
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

  def initialize(id:, name:, description:, path:)
    @id = id
    @name = name
    @description = description
    @path = path
  end

  def load
    content = read_cached(@path)
    return nil unless content

    {
      content: content,
      version: Digest::SHA1.hexdigest(content)[0, 8]
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
