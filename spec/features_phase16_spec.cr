require "./support/feature_client"
require "./support/prelude"

# Phase 16: type definition and declaration.

private APP = {
  "src/app.cr" => <<-CR,
    class Point
      @x : Int32 = 0

      def x_value
        @x
      end

      def self.origin : Point
        new
      end
    end

    class Point
      def y; end
    end

    struct Pair(A, B)
    end

    def find(n : Int32) : Point?
      n > 0 ? Point.new : nil
    end

    def run(points : Array(Point))
      p = Point.new
      maybe = find(1)
      names = points.map { |pt| pt.x_value }
      pair = Pair(Int32, String).new
      tup = {1, "a"}
      Point.origin
      Point
      cls = Point
      what = unknown_call
      p
    end
    CR
}

private def type_defs(c : FeatureClient, needle : String, shift = 0) : Array({String, Int32})
  u = c.uri("src/app.cr")
  r = c.request("textDocument/typeDefinition", {textDocument: {uri: u}, position: c.pos("src/app.cr", needle, shift)})
  r.as_a.map { |l| {l["uri"].as_s.split('/').last, l["range"]["start"]["line"].as_i + 1} }
end

describe "phase 16 type definition" do
  it "advertises typeDefinition and declaration" do
    with_client(APP, PRELUDE_FILES) do |c|
      caps = c.init_result["capabilities"]
      caps["typeDefinitionProvider"].should eq true
      caps["declarationProvider"].should eq true
    end
  end

  it "goes to the type of a local, each reopening once" do
    with_client(APP, PRELUDE_FILES) do |c|
      c.open("src/app.cr")
      type_defs(c, "  p\nend", 2).should eq [{"app.cr", 1}]
      type_defs(c, "p = Point").should eq [{"app.cr", 1}]
    end
  end

  it "adds workspace reopenings in other files" do
    files = APP.merge({"shard.yml" => "name: p\ntargets:\n  p:\n    main: src/main.cr\n", "src/ext.cr" => "class Point\n  def z; end\nend\n", "src/main.cr" => "require \"./app\"\nrequire \"./ext\"\n"})
    with_client(files, PRELUDE_FILES) do |c|
      c.open("src/app.cr")
      type_defs(c, "p = Point").should eq [{"app.cr", 1}, {"ext.cr", 1}]
    end
  end

  it "lists every member of a union, Nil included" do
    with_client(APP, PRELUDE_FILES) do |c|
      c.open("src/app.cr")
      r = type_defs(c, "maybe = ")
      r.should contain({"app.cr", 1})
      r.map(&.[0]).should contain("object.cr") # struct Nil
      r.size.should eq 2
    end
  end

  it "goes to the generic type, not its arguments" do
    with_client(APP, PRELUDE_FILES) do |c|
      c.open("src/app.cr")
      type_defs(c, "names = ").map(&.[0]).should eq ["enumerable.cr"] # class Array(T)
      type_defs(c, "pair = ").should eq [{"app.cr", 17}]
    end
  end

  it "covers block arguments, ivars, tuples and call results" do
    with_client(APP, PRELUDE_FILES) do |c|
      c.open("src/app.cr")
      type_defs(c, "pt.x_value", 0).should eq [{"app.cr", 1}]
      type_defs(c, "    @x\n", 4).map(&.[0]).should eq ["object.cr"] # Int32
      type_defs(c, "tup = ").map(&.[0]).should eq ["enumerable.cr"]  # Tuple
      type_defs(c, "origin\n").should eq [{"app.cr", 1}]
    end
  end

  it "goes to the type itself on a constant or its metaclass" do
    with_client(APP, PRELUDE_FILES) do |c|
      c.open("src/app.cr")
      type_defs(c, "  Point\n  cls", 2).should eq [{"app.cr", 1}]
      type_defs(c, "cls = ").should eq [{"app.cr", 1}]
    end
  end

  it "gives nothing for unknown types" do
    with_client(APP, PRELUDE_FILES) do |c|
      c.open("src/app.cr")
      type_defs(c, "what = ").should be_empty
    end
  end

  it "answers declaration like definition" do
    with_client(APP, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      pos = c.pos("src/app.cr", "x_value }")
      d = c.request("textDocument/definition", {textDocument: {uri: u}, position: pos})
      c.request("textDocument/declaration", {textDocument: {uri: u}, position: pos}).should eq d
      d.as_a.size.should eq 1
    end
  end
end

private def hunks(old, new)
  Server.line_hunks(old, new).map { |h| {h.old_start, h.old_count, h.new_text} }
end

describe "phase 16 line hunks" do
  it "splits a diff into hunks" do
    hunks("a\nb\nc\n", "a\nb\nc\n").should be_empty
    hunks("a\n b\nc\n d\ne\n", "a\nb\nc\nd\ne\n").should eq [{1, 1, "b\n"}, {3, 1, "d\n"}]
    hunks("a\nc\n", "a\nb\nc\n").should eq [{1, 0, "b\n"}]
    hunks("a\nb\nc\n", "a\nc\n").should eq [{1, 1, ""}]
    hunks("a\n b\n c\nd\n", "a\nb\nc\nd\n").should eq [{1, 2, "b\nc\n"}]
    hunks("x\n", "").should eq [{0, 1, ""}]
    hunks("", "x\n").should eq [{0, 0, "x\n"}]
  end

  it "reproduces the new text when every hunk is applied" do
    rng = Random.new(16)
    200.times do
      a = Array.new(rng.rand(0..12)) { %w(a b c d e).sample(rng) + "\n" }
      b = a.dup
      rng.rand(0..5).times do
        case rng.rand(3)
        when 0 then b.insert(rng.rand(0..b.size), %w(a b x y).sample(rng) + "\n")
        when 1 then b.delete_at(rng.rand(0...b.size)) unless b.empty?
        else        (b[rng.rand(0...b.size)] = "z\n") unless b.empty?
        end
      end
      old, new = a.join, b.join
      lines = a.dup
      Server.line_hunks(old, new).reverse_each do |h|
        lines[h.old_start, h.old_count] = h.new_text.lines(chomp: false)
      end
      lines.join.should eq new
    end
  end

  it "keeps the hunks touching the range" do
    old = "a\n b\nc\n d\ne\n"
    new = "a\nb\nc\nd\ne\n"
    Server.hunks_in_range(old, new, 1, 1).map(&.old_start).should eq [1]
    Server.hunks_in_range(old, new, 3, 4).map(&.old_start).should eq [3]
    Server.hunks_in_range(old, new, 0, 4).map(&.old_start).should eq [1, 3]
    Server.hunks_in_range(old, new, 2, 2).should be_empty
    # An insertion right after the selected line belongs to it.
    Server.hunks_in_range("a\nc\n", "a\nb\nc\n", 0, 0).size.should eq 1
    # Deletion then insertion: the second is kept with the first.
    Server.hunks_in_range("a\nx\nb\nc\n", "a\nb\ny\nc\n", 1, 1).map { |h| {h.old_start, h.old_count} }.should eq [{1, 1}, {3, 0}]
  end
end

private UNFORMATTED = <<-CR
  class Foo
    def a
      x   =   1
      y = {a:   1,
        bcd: 2}
      x+y.size
    end

    def b( x )
      x+1
    end
  end

  CR

private def range_format(c : FeatureClient, u : String, first : Int32, last : Int32, last_col = 1)
  c.request("textDocument/rangeFormatting", {textDocument: {uri: u}, range: {start: {line: first, character: 0}, end: {line: last, character: last_col}}, options: {tabSize: 2, insertSpaces: true}})
end

describe "phase 16 range formatting" do
  it "advertises rangeFormatting" do
    with_client({"a.cr" => "x = 1\n"}) do |c|
      c.init_result["capabilities"]["documentRangeFormattingProvider"].should eq true
    end
  end

  it "formats only the hunks of the selected lines, with the file's indentation" do
    with_client({"a.cr" => UNFORMATTED}) do |c|
      u = c.open("a.cr")
      edits = range_format(c, u, 2, 2).as_a
      edits.size.should eq 1
      edits[0]["range"].should eq JSON.parse(%({"start":{"line":2,"character":0},"end":{"line":3,"character":0}}))
      edits[0]["newText"].should eq "    x = 1\n"
      # The hash continuation is aligned against its first line.
      range_format(c, u, 4, 5).as_a.map(&.["newText"].as_s).should eq ["         bcd: 2}\n    x + y.size\n"]
      edits = range_format(c, u, 9, 9).as_a
      edits.map(&.["newText"].as_s).should eq ["  def b(x)\n    x + 1\n"]
    end
  end

  it "gives no edits for an already formatted range" do
    with_client({"a.cr" => "def a\n  1\nend\n\ndef b( x )\n  x\nend\n"}) do |c|
      u = c.open("a.cr")
      range_format(c, u, 0, 2).as_a.should be_empty
      range_format(c, u, 4, 4).as_a.size.should eq 1
    end
  end

  it "does not take the line a range ends at column 0" do
    with_client({"a.cr" => "x  =  1\nz\ny  =  2\n"}) do |c|
      u = c.open("a.cr")
      range_format(c, u, 0, 2, 0).as_a.map(&.["newText"].as_s).should eq ["x = 1\n"]
    end
  end

  it "returns null on a syntax error anywhere" do
    with_client({"a.cr" => "x  =  1\ndef foo(\n"}) do |c|
      u = c.open("a.cr")
      range_format(c, u, 0, 0).raw.should be_nil
      c.notifications("window/logMessage").last["message"].as_s.should contain "syntax error"
    end
  end
end
