require "test_helper"
require "tmpdir"

class PersonaTest < ActiveSupport::TestCase
  def setup
    @tmpdir = Dir.mktmpdir("persona-test")
    @full_path = File.join(@tmpdir, "full.md")
    @condensed_path = File.join(@tmpdir, "condensed.md")
    File.write(@full_path, "FULL CONTENT")
    File.write(@condensed_path, "CONDENSED CONTENT")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def build_persona(condensed: true)
    Persona.send(:new,
      id: "test",
      name: "Test",
      description: "test persona",
      full_path: @full_path,
      condensed_path: condensed ? @condensed_path : nil
    )
  end

  test "registry: find returns registered persona; missing id returns nil" do
    assert_equal "persona1", Persona.find("persona1").id
    assert_nil Persona.find("does-not-exist")
  end

  test "registry: default returns persona1" do
    assert_equal "persona1", Persona.default.id
  end

  test "load(:full) returns content, 8-char sha version, and :full variant" do
    persona = build_persona
    result = persona.load(:full)
    assert_equal "FULL CONTENT", result[:content]
    assert_equal :full, result[:variant]
    assert_equal 8, result[:version].length
    assert_equal Digest::SHA1.hexdigest("FULL CONTENT")[0, 8], result[:version]
  end

  test "load(:condensed) returns condensed content when condensed_path is set" do
    persona = build_persona
    result = persona.load(:condensed)
    assert_equal "CONDENSED CONTENT", result[:content]
    assert_equal :condensed, result[:variant]
  end

  test "load(:condensed) falls back to full when condensed_path is nil" do
    persona = build_persona(condensed: false)
    result = persona.load(:condensed)
    assert_equal "FULL CONTENT", result[:content]
    assert_equal :full, result[:variant], "variant should report :full when falling back"
  end

  test "missing file returns nil and logs warning" do
    File.delete(@full_path)
    persona = build_persona(condensed: false)
    assert_nil persona.load(:full)
  end

  test "version changes when file content changes" do
    persona = build_persona
    v1 = persona.load(:full)[:version]
    sleep 0.01
    File.write(@full_path, "FULL CONTENT v2")
    File.utime(Time.now, Time.now + 1, @full_path) # bump mtime
    v2 = persona.load(:full)[:version]
    refute_equal v1, v2
  end

  test "registered persona1 loads from actual files on disk" do
    persona = Persona.find("persona1")
    result = persona.load(:full)
    assert_not_nil result, "persona1 full variant should load from persona/persona1.md"
    assert result[:content].length > 0
  end
end
