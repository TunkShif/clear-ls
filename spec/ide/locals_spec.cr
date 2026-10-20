require "../spec_helper"

include ClearLS

private def locals(src : String) : {IDE::Locals, String}
  vfs = VFS.new
  state = vfs.open("file:///t.cr", src, 1)
  {IDE::Locals.new(state, IDE::Bodies.new(state)), src}
end

private def at(src : String, needle : String, shift = 0, nth = 0) : UInt32
  off = -1
  (nth + 1).times { off = src.byte_index(needle, off + 1).not_nil! }
  (off + shift).to_u32
end

private def texts(src : String, ranges : Enumerable(TextRange)) : Array(String)
  ranges.map { |r| "#{src.byte_slice(0, r.start).count('\n') + 1}:#{src.byte_slice(r.start, r.size)}" }
end

describe IDE::Locals do
  src = <<-CR
    def greet(name, times = 1)
      message = "hi \#{name}"
      times.times do |i|
        message += i.to_s
      end
      message
    end
    CR

  it "finds the definition from any reference, with left or right bias" do
    l, s = locals(src)
    decl = at(s, "message")
    l.definition(at(s, "message", nth: 2)).should eq TextRange.new(decl, decl + 7)
    # Cursor right after the token (`message|`) and right before (`|message`).
    l.definition(at(s, "message", 7, nth: 2)).should eq TextRange.new(decl, decl + 7)
    l.definition(at(s, "message", 0, nth: 2)).should eq TextRange.new(decl, decl + 7)
    # Interpolated param.
    l.definition(at(s, "name}")).should eq TextRange.new(at(s, "name"), at(s, "name") + 4)
  end

  it "returns references and highlights" do
    l, s = locals(src)
    texts(s, l.references(at(s, "message")).map(&.range)).should eq ["2:message", "4:message", "4:message", "6:message"]
    texts(s, l.references(at(s, "i.to_s"), include_decl: false).map(&.range)).should eq ["4:i"]
  end

  it "does not treat method calls or other words as locals" do
    l, s = locals(src)
    l.definition(at(s, "to_s", 1)).should be_nil
    l.definition(at(s, "greet", 1)).should be_nil
    l.definition(at(s, "\"hi", 1)).should be_nil
  end

  it "renames locals in their scope only" do
    l, s = locals("def m\n  x = 1\n  [1].each { |x| x }\n  x\nend")
    edits = l.rename(at(s, "x", nth: 3), "count").not_nil!
    texts(s, edits.map(&.[0])).should eq ["2:x", "4:x"]
    edits.map(&.[1]).uniq.should eq ["count"]
  end

  it "rejects invalid new names and ivar-backed params" do
    l, s = locals("def initialize(@name)\n  name\nend")
    l.rename(at(s, "name", nth: 1), "other").should be_nil
    l2, s2 = locals("def m(a)\n  a\nend")
    l2.rename(at(s2, "a", nth: 1), "Bad").should be_nil
    l2.rename(at(s2, "a", nth: 1), "end").should be_nil
    l2.rename(at(s2, "a", nth: 1), "ok_2").should_not be_nil
  end

  it "works on top-level script locals" do
    l, s = locals("total = 0\n[1, 2].each { |n| total += n }\nputs total\n")
    texts(s, l.references(at(s, "total", nth: 2)).map(&.range)).should eq ["1:total", "2:total", "2:total", "3:total"]
  end
end
