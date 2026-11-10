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
