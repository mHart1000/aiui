require "test_helper"
require "tmpdir"

class PersonaTest < ActiveSupport::TestCase
  def setup
    @tmpdir = Dir.mktmpdir("persona-test")
    @path = File.join(@tmpdir, "persona.md")
    File.write(@path, "PERSONA CONTENT")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def build_persona
    Persona.send(:new, id: "test", name: "Test", description: "test persona", path: @path)
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
end
