require "test_helper"
require "tmpdir"

class PersonaTest < ActiveSupport::TestCase
  def setup
    @tmpdir = Dir.mktmpdir("persona-test")
    @path = File.join(@tmpdir, "persona.md")
    File.write(@path, "PERSONA CONTENT")
    @modifier_path = File.join(@tmpdir, "modifier.md")
    File.write(@modifier_path, "MODIFIER CONTENT")
    Persona.register_modifier(id: "test-mod", path: @modifier_path)
  end

  def teardown
    # Not reset!, which would clear the personas registered at boot.
    Persona::MODIFIERS.delete("test-mod")
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def build_persona(skip_modifiers: [])
    Persona.send(:new, id: "test", name: "Test", description: "test persona", path: @path, skip_modifiers: skip_modifiers)
  end

  test "registry: find returns registered persona; missing id returns nil" do
    assert_equal "persona1", Persona.find("persona1").id
    assert_nil Persona.find("does-not-exist")
  end

  test "registry: default returns persona1" do
    assert_equal "persona1", Persona.default.id
  end

  test "registry: all three personas are registered" do
    ids = Persona.ids
    assert_includes ids, "persona1"
    assert_includes ids, "persona2"
    assert_includes ids, "persona2-condensed"
  end

  test "load returns content and 8-char sha version" do
    persona = build_persona
    result = persona.load
    assert_equal "PERSONA CONTENT", result[:content]
    assert_equal 8, result[:version].length
    assert_equal Digest::SHA1.hexdigest("PERSONA CONTENT")[0, 8], result[:version]
  end

  test "missing file returns nil" do
    File.delete(@path)
    persona = build_persona
    assert_nil persona.load
  end

  test "version changes when file content changes" do
    persona = build_persona
    v1 = persona.load[:version]
    File.write(@path, "PERSONA CONTENT v2")
    File.utime(Time.now, Time.now + 1, @path)
    v2 = persona.load[:version]
    refute_equal v1, v2
  end

  test "each registered persona loads from disk" do
    Persona.all.each do |persona|
      result = persona.load
      assert_not_nil result, "#{persona.id} should load from #{persona.path}"
      assert result[:content].length > 0
    end
  end

  test "modifier is appended after the persona" do
    result = build_persona.load(modifiers: [ "test-mod" ])
    assert_equal "PERSONA CONTENT\n\nMODIFIER CONTENT", result[:content]
    assert_equal [ "test-mod" ], result[:modifiers]
  end

  test "load without modifiers is unchanged" do
    result = build_persona.load
    assert_equal "PERSONA CONTENT", result[:content]
    assert_empty result[:modifiers]
    assert_equal Digest::SHA1.hexdigest("PERSONA CONTENT")[0, 8], result[:version]
  end

  test "a modifier changes the version" do
    persona = build_persona
    refute_equal persona.load[:version], persona.load(modifiers: [ "test-mod" ])[:version]
  end

  test "skip_modifiers suppresses a modifier the persona already covers" do
    persona = build_persona(skip_modifiers: [ "test-mod" ])
    result = persona.load(modifiers: [ "test-mod" ])
    assert_equal "PERSONA CONTENT", result[:content]
    assert_empty result[:modifiers]
    assert_equal persona.load[:version], result[:version]
  end

  test "unregistered modifier is skipped and the persona still loads" do
    result = build_persona.load(modifiers: [ "does-not-exist" ])
    assert_equal "PERSONA CONTENT", result[:content]
    assert_empty result[:modifiers]
  end

  test "modifiers are not selectable personas" do
    assert_not_includes Persona.ids, "test-mod"
    assert_not_includes Persona.all.map(&:path), @modifier_path
  end

  test "registry: voice modifier is registered and loads from disk" do
    assert_not_nil Persona.modifier("voice")
    assert Persona.modifier("voice").content.to_s.length > 0
  end

  test "registry: self-contained voice personas ignore the voice modifier" do
    %w[voice interviewer].each do |id|
      persona = Persona.find(id)
      assert_equal persona.load[:version],
                   persona.load(modifiers: [ "voice" ])[:version],
                   "#{id} should ignore the voice modifier"
    end
  end

  test "registry: plainspoken layers the voice modifier" do
    persona = Persona.find("plainspoken")
    result = persona.load(modifiers: [ "voice" ])
    assert_equal [ "voice" ], result[:modifiers]
    assert result[:content].start_with?(persona.content)
    assert_includes result[:content], Persona.modifier("voice").content
  end
end
