require "../spec_helper"

include ClearLS
include ClearLS::Syntax

private SAMPLE = <<-CR
  module Greeting
    class Greeter < Base
      include Comparable(Greeter)

      def initialize(@name : String, loud = false)
      end

      def greet(io : IO, *args, **opts, &block) : Nil
        if @name.empty?
          io << "hello, 中文 😀"
        else
          [1, 2, 3].each { |x| io << x * 2 }
        end
      end
    end
  end
  CR

describe Syntax::Parser do
  parser = Syntax::Parser.new

  it "parses into typed kinds and fields" do
    tree = parser.parse(SAMPLE)
    tree.has_error?.should be_false
    root = tree.root
    root.kind.should eq Kind::Expressions

    mod = root.named_child(0).not_nil!
    mod.kind.should eq Kind::ModuleDef
    mod.field(Field::Name).not_nil!.text.should eq "Greeting"

    cls = mod.field(Field::Body).not_nil!.named_child(0).not_nil!
    cls.kind.should eq Kind::ClassDef
    cls.field(Field::Superclass).not_nil!.text.should eq "Base"

    defs = [] of Node
    root.walk { |n| defs << n if n.kind.method_def?; true }
    defs.map { |d| d.field(Field::Name).not_nil!.text }.should eq ["initialize", "greet"]
    params = defs[1].field(Field::Params).not_nil!.named_children.map(&.kind)
    params.should eq [Kind::Param, Kind::SplatParam, Kind::DoubleSplatParam, Kind::BlockParam]
  end

  it "keeps byte ranges consistent with text" do
    tree = parser.parse(SAMPLE)
    str = nil
    tree.root.walk { |n| str ||= n if n.kind.string_node?; true }
    str.not_nil!.text.should eq %("hello, 中文 😀")
  end

  it "finds descendants by byte offset" do
    tree = parser.parse(SAMPLE)
    off = SAMPLE.byte_index("greet").not_nil!.to_u32
    leaf = tree.root.descendant(off + 2).not_nil!
    leaf.kind.should eq Kind::Identifier
    leaf.parent.not_nil!.kind.should eq Kind::MethodDef
  end

  it "recovers from syntax errors with local ERROR/MISSING nodes" do
    # Incomplete code typed in the middle of a class keeps later defs.
    ["    x.\n", "    if x\n", "    y = \n"].each do |broken|
      tree = parser.parse("class A\n  def foo\n#{broken}  end\n  def bar; end\nend\n")
      tree.has_error?.should be_true
      names = [] of String
      tree.root.walk do |n|
        names << n.field(Field::Name).not_nil!.text if n.kind.method_def? && n.field(Field::Name)
        true
      end
      names.should eq ["foo", "bar"]
    end
  end

  it "recovers an unclosed parameter list by swallowing following lines" do
    # Known grammar behaviour (docs/tree-sitter-grammar-notes.md).
    tree = parser.parse("class A\n  def foo(\n  end\n  def bar; end\nend\n")
    missing = false
    tree.root.walk { |n| missing = true if n.missing?; true }
    missing.should be_true
  end

  it "maps ERROR nodes to Kind::Error" do
    tree = parser.parse("def x(\n")
    found = false
    tree.root.walk { |n| found = true if n.error? && n.kind.error?; true }
    found.should be_true
  end

  it "reparses incrementally and reports changed ranges" do
    old = parser.parse(SAMPLE)
    off = SAMPLE.byte_index("[1, 2, 3]").not_nil!.to_u32
    tree = parser.reparse(old, [TextEdit.new(TextRange.new(off + 1, off + 2), "10")])
    tree.text.should contain("[10, 2, 3]")
    tree.root.sexp.should eq parser.parse(tree.text).root.sexp
    old.text.should eq SAMPLE

    edit = TextEdit.insert(off, "x = 1; ")
    ranges = parser.reparse(old, [edit]).changed_ranges.not_nil!
    ranges.should_not be_empty
    ranges.all? { |r| r.start >= SAMPLE.byte_index("def greet").not_nil! }.should be_true
  end

  it "applies sequential edits like LSP incremental sync" do
    old = parser.parse("a = 1\n")
    edits = [TextEdit.insert(5, "\nb = 2"), TextEdit.new(TextRange.new(0, 1), "abc")]
    tree = parser.reparse(old, edits)
    tree.text.should eq "abc = 1\nb = 2\n"
    tree.root.sexp.should eq parser.parse(tree.text).root.sexp
  end

  it "matches a fresh parse after random edits (property)" do
    rng = Random.new(7)
    snippets = ["def ", "end", "\n", "(", ")", " if x", "中", "😀", "\"", "#{", "}",
                "do |a|", "x.y", "@z", "1", " ", "class B", ":sym", "[]"]
    20.times do
      tree = parser.parse(SAMPLE)
      30.times do
        size = tree.text.bytesize
        a = rng.rand(0..size)
        b = Math.min(size, a + rng.rand(0..8))
        # Keep edits on character boundaries, like a real editor.
        bytes = tree.text.to_slice
        while a < size && bytes[a] & 0xC0 == 0x80
          a -= 1
        end
        b = Math.max(a, b)
        while b < size && bytes[b] & 0xC0 == 0x80
          b += 1
        end
        insert = rng.rand < 0.3 ? "" : snippets.sample(rng)
        tree = parser.reparse(tree, [TextEdit.new(TextRange.new(a.to_u32, b.to_u32), insert)])
        tree.root.sexp.should eq parser.parse(tree.text).root.sexp
      end
    end
  end
end

describe "Syntax helpers" do
  parser = Syntax::Parser.new

  it "skips punctuation tagged with a field" do
    tree = parser.parse("def f(x : Int32 = 1) : String; end")
    m = tree.root.named_child(0).not_nil!
    m.field(Field::Type).not_nil!.text.should eq "String"
    param = m.field(Field::Params).not_nil!.named_child(0).not_nil!
    param.field_text(Field::Type).should eq "Int32"
    param.field_text(Field::Default).should eq "1"
  end

  it "parses selected ranges in original coordinates" do
    text = "{% if a %}\n  class W; end\n{% end %}\nclass X; end\n"
    start = text.index!("class W").to_u32
    tree = parser.parse_ranges(text, [TextRange.new(start, start + 12)])
    cls = tree.root.named_child(0).not_nil!
    cls.kind.should eq Kind::ClassDef
    cls.field_text(Field::Name).should eq "W"
    cls.start_byte.should eq start
    # The parser is reusable for full parses afterwards.
    parser.parse(text).root.named_child_count.should eq 2
  end
end
