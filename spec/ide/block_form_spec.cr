require "../spec_helper"

include ClearLS

private def state_of(text : String) : FileState
  vfs = VFS.new
  vfs.open("file:///t.cr", text, 1)
end

private def apply(text : String, needle : String, shift = 0) : String | Nil
  st = state_of(text)
  r = IDE::BlockForm.convert(st, (text.index!(needle) + shift).to_u32)
  return nil unless r.is_a?(IDE::BlockForm::Edit)
  text.byte_slice(0, r.range.start) + r.text + text.byte_slice(r.range.end, text.bytesize - r.range.end)
end

private def refusal(text : String, needle : String) : String?
  r = IDE::BlockForm.convert(state_of(text), text.index!(needle).to_u32)
  r.as?(String)
end

describe IDE::BlockForm do
  it "converts braces to do ... end and back" do
    src = "def go(xs)\n  xs.each { |x| puts x }\nend\n"
    res = apply(src, "puts").not_nil!
    res.should eq "def go(xs)\n  xs.each do |x|\n    puts x\n  end\nend\n"
    apply(res, "puts").should eq src
  end

  it "keeps destructuring params, several statements and nesting" do
    src = "xs.each_with_index { |(a, b), i| p a; p b }\n"
    res = apply(src, "p a").not_nil!
    res.should eq "xs.each_with_index do |(a, b), i|\n  p a\n  p b\nend\n"
    multi = "xs.map do |x|\n  if x\n    1\n  end\nend\n"
    res = apply(multi, "if x").not_nil!
    res.should eq "xs.map { |x|\n  if x\n    1\n  end\n}\n"
    apply(res, "if x").should eq multi
  end

  it "converts blocks without parameters or body" do
    apply("loop { }\n", "{").should eq "loop do\nend\n"
    apply("loop do\nend\n", "do").should eq "loop { }\n"
  end

  it "refuses when the block would bind to another call" do
    refusal("foo bar { 1 }\n", "1").not_nil!.should contain "pass the block to `foo`"
    refusal("foo bar do\n  1\nend\n", "1").not_nil!.should contain "last argument"
    refusal("record P do\n  def x; end\nend\n", "def").not_nil!.should contain "macro body"
    refusal("loop do\n  a\nrescue\n  b\nend\n", "a").not_nil!.should contain "rescue"
    refusal("record P do\n  ECR.def_to_s \"x\"\nend\n", "ECR").not_nil!.should contain "last argument"
    # Parenthesized arguments are safe both ways.
    apply("foo(bar) do\n  1\nend\n", "1").should eq "foo(bar) { 1 }\n"
    apply("foo(bar { 1 })\n", "1").should eq "foo(bar do\n  1\nend)\n"
  end

  # A sample by default; `BLOCK_FILES=9999 BLOCKS_PER_FILE=9999` runs
  # every block of the stdlib (~4 min).
  it "round-trips every convertible block of the stdlib" do
    stdlib = Workspace::Project.detect(Dir.current).stdlib_dir.not_nil!
    files = Dir.glob(File.join(stdlib, "**/*.cr")).sort.first((ENV["BLOCK_FILES"]? || "120").to_i)
    parser = Syntax::Parser.new
    converted = 0
    files.each do |path|
      text = File.read(path)
      tree = parser.parse(text)
      next if tree.root.has_error?
      starts = [] of UInt32
      tree.root.walk { |n| starts << n.start_byte if n.kind.block? && n.parent.try(&.field(Syntax::Field::Block)) == n; true }
      starts.first((ENV["BLOCKS_PER_FILE"]? || "20").to_i).each do |s|
        st = state_of(text)
        r = IDE::BlockForm.convert(st, s + 1)
        next unless r.is_a?(IDE::BlockForm::Edit)
        once = text.byte_slice(0, r.range.start) + r.text + text.byte_slice(r.range.end, text.bytesize - r.range.end)
        parser.parse(once).root.has_error?.should be_false, "#{path}@#{s}: conversion does not parse"
        st2 = state_of(once)
        r2 = IDE::BlockForm.convert(st2, s + 1)
        r2.should be_a(IDE::BlockForm::Edit), "#{path}@#{s}: no way back (#{r2})"
        r2 = r2.as(IDE::BlockForm::Edit)
        twice = once.byte_slice(0, r2.range.start) + r2.text + once.byte_slice(r2.range.end, once.bytesize - r2.range.end)
        # `a; b` becomes two lines: separators are equal.
        norm = ->(t : String) { t.gsub(/\s*;\s*|\s+/, " ") }
        norm.call(twice).should eq(norm.call(text)), "#{path}@#{s}: round trip changed the code"
        converted += 1
      end
    end
    converted.should be > 300
  end
end
