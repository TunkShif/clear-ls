require "./spec_helper"
require "./support/feature_client"
require "./support/prelude"

REFS_APP = {
  "shard.yml"   => "name: app\ntargets:\n  app:\n    main: src/app.cr\n",
  "src/app.cr"  => <<-CR,
    require "./shapes"

    def area_of(s : Shape) : Int32
      s.area
    end

    sq = Square.new
    sq.area
    sq.name
    c = Circle.new
    c.area
    puts Square::SIDES
    CR
  "src/shapes.cr" => <<-CR,
    abstract class Shape
      abstract def area : Int32
    end

    class Square < Shape
      SIDES = 4

      def area : Int32
        SIDES * 2
      end

      def name : String
        "square"
      end
    end

    class Circle < Shape
      def area : Int32
        3
      end

      # Same name, unrelated type.
      def name : String
        "circle"
      end
    end

    class Square
      def describe(other)
        other.name
      end
    end
    CR
  # Unrelated program: its Square is not the project's.
  "scripts/other.cr" => "class Square\n  def area : Int32\n    1\n  end\nend\nSquare.new.area\n",
}

private def refs(c, path, needle, shift = 0, decl = true) : Array(String)
  u = c.open(path)
  r = c.request("textDocument/references", {textDocument: {uri: u}, position: c.pos(path, needle, shift), context: {includeDeclaration: decl}})
  r.as_a.map { |x| "#{x["uri"].as_s.split("/src/").last.split("/").last}:#{x["range"]["start"]["line"].as_i + 1}:#{x["range"]["start"]["character"].as_i}" }
end

describe "workspace references" do
  it "finds method uses by identity across files" do
    with_client(REFS_APP, PRELUDE_FILES) do |c|
      # From the call `sq.area`: Square#area only (not Circle#area, not the
      # other program's Square#area).
      refs(c, "src/app.cr", "sq.area", 3).should eq ["app.cr:8:3", "shapes.cr:8:6"]
      # From the declaration: same set.
      refs(c, "src/shapes.cr", "area : Int32\n    SIDES", 0).should eq ["app.cr:8:3", "shapes.cr:8:6"]
      refs(c, "src/shapes.cr", "area : Int32\n    SIDES", 0, decl: false).should eq ["app.cr:8:3"]
      # Abstract def: the virtual call `s.area` on Shape.
      refs(c, "src/app.cr", "s.area", 2).should contain("app.cr:4:4")
    end
  end

  it "keeps possible references out unless asked" do
    with_client(REFS_APP, PRELUDE_FILES) do |c|
      # `other.name` (untyped param) may be Square#name: not exact.
      refs(c, "src/app.cr", "sq.name", 3).should eq ["app.cr:9:3", "shapes.cr:12:6"]
    end
    with_client(REFS_APP, PRELUDE_FILES, references: {includePossible: true}) do |c|
      refs(c, "src/app.cr", "sq.name", 3).should eq ["app.cr:9:3", "shapes.cr:12:6", "shapes.cr:30:10"]
    end
  end

  it "finds type and constant uses, including reopenings" do
    with_client(REFS_APP, PRELUDE_FILES) do |c|
      got = refs(c, "src/app.cr", "Square.new")
      got.should eq ["app.cr:7:5", "app.cr:12:5", "shapes.cr:5:6", "shapes.cr:28:6"]
      refs(c, "src/app.cr", "SIDES").should eq ["app.cr:12:13", "shapes.cr:6:2", "shapes.cr:9:4"]
    end
  end

  it "keeps the local path for locals" do
    with_client(REFS_APP, PRELUDE_FILES) do |c|
      refs(c, "src/app.cr", "sq = ").should eq ["app.cr:7:0", "app.cr:8:0", "app.cr:9:0"]
    end
  end
end

IVAR_APP = {
  "shard.yml"  => "name: app\ntargets:\n  app:\n    main: src/app.cr\n",
  "src/app.cr" => <<-CR,
    class Item
      @count : Int32 = 0
      property name = "hello"

      def initialize(@price : Int32)
      end

      def touch
        @seen = true
      end

      def reset
        @seen = false
      end

      def say_my_name
        print @name, @count, @price, @seen
      end
    end

    class Special < Item
      def bump
        @count += 1
      end
    end

    class Other
      def initialize
        @count = 5
      end

      def get
        @count
      end
    end
    CR
}

private def defs_of(c, needle, shift) : Array(String)
  u = c.open("src/app.cr")
  r = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", needle, shift)})
  r.as_a.map { |x| "#{x["range"]["start"]["line"].as_i + 1}:#{x["range"]["start"]["character"].as_i}" }
end

describe "ivar definitions and references" do
  it "jumps to the strongest declaration category" do
    with_client(IVAR_APP, PRELUDE_FILES) do |c|
      defs_of(c, "@name, @count", 1).should eq ["3:11"]        # property name
      defs_of(c, "@count, @price", 1).should eq ["2:2"]        # @count : Int32
      defs_of(c, "@price, @seen", 1).should eq ["5:17"]        # initialize(@price)
      defs_of(c, "@seen\n", 1).should eq ["9:4", "13:4"]       # every assignment
      defs_of(c, "@count += 1", 1).should eq ["2:2"]           # inherited
    end
  end

  it "finds uses in the owner and its subtypes only" do
    with_client(IVAR_APP, PRELUDE_FILES) do |c|
      got = refs(c, "src/app.cr", "@count, @price", 1)
      got.should eq ["app.cr:2:2", "app.cr:17:17", "app.cr:23:4"] # not Other's @count
      refs(c, "src/app.cr", "@count = 5", 1).should eq ["app.cr:29:4", "app.cr:33:4"]
    end
  end

  it "completes initialize(@x) ivars from other files" do
    files = {
      "shard.yml"  => "name: app\ntargets:\n  app:\n    main: src/app.cr\n",
      "src/app.cr" => "require \"./base\"\nclass Sub < Base\n  def f\n    @\n  end\nend\n",
      "src/base.cr" => "class Base\n  def initialize(@price : Int32)\n  end\nend\n",
    }
    with_client(files, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      r = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: 3, character: 5}})
      r["items"].as_a.map { |i| {i["label"].as_s, i["detail"].as_s?} }.should contain({"@price", "Int32"})
    end
  end
end
