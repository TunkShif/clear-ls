require "./support/feature_client"
require "./support/prelude"

FEEDBACK_APP = {
  "src/fb.cr" => <<-CR,
    class Counter
      @count : Int32 = 0
      @@instances = 0
      getter label : String

      def initialize(@label : String)
      end

      # Builds a counter.
      def self.build(label : String) : Counter
        @@instances
        new(label)
      end

      def bump : Int32
        self.label
        @count
      end

      def self.make : Counter
        self.build("x")
      end

      self.make

      def +(other : Counter) : Int32
        0
      end
    end

    def run(c : Counter)
      x = 
    end
    CR
}

private def fb_hover(c, needle, shift = 0) : String?
  u = c.open("src/fb.cr")
  h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/fb.cr", needle, shift)})
  h.raw.nil? ? nil : h["contents"]["value"].as_s
end

describe "completion order and declaration hovers" do
  it "lists own methods before Object methods and operators" do
    c = FeatureClient.new(FEEDBACK_APP, PRELUDE_FILES)
    uri = c.open("src/fb.cr")
    pos = c.pos("src/fb.cr", "x = \n", 4)
    c.notify("textDocument/didChange", {textDocument: {uri: uri, version: 2}, contentChanges: [{range: {start: pos, end: pos}, text: "c."}]})
    res = c.request("textDocument/completion", {textDocument: {uri: uri}, position: {line: pos[:line], character: pos[:character] + 2}})
    labels = res["items"].as_a.sort_by(&.["sortText"].as_s).map(&.["label"].as_s)
    own = labels.index!("bump")
    labels.index!("label").should be < labels.index!("to_s")
    own.should be < labels.index!("to_s")  # Object method
    labels.index!("to_s").should be < labels.index!("+") # operator last
    labels.last.should eq "+"
  ensure
    c.try(&.cleanup)
  end

  it "hovers ivars, cvars, and def headers" do
    with_client(FEEDBACK_APP, PRELUDE_FILES) do |c|
      fb_hover(c, "@count\n").not_nil!.should contain("@count : Int32")
      fb_hover(c, "@count : Int32").not_nil!.should contain("instance variable of `Counter`")
      fb_hover(c, "@label : String)").not_nil!.should contain("@label : String")
      fb_hover(c, "@@instances\n    new").not_nil!.should contain("class variable")
      h = fb_hover(c, "build").not_nil!
      h.should contain("def Counter.build(label : String) : Counter")
      h.should contain("Builds a counter.")
      fb_hover(c, "self.build").not_nil!.should contain("`self` is `Counter.class`")
      fb_hover(c, "bump : Int32").not_nil!.should contain("def Counter#bump() : Int32")
      fb_hover(c, "self.label").not_nil!.should contain("self : Counter\n")
      fb_hover(c, "self.build(\"x").not_nil!.should contain("self : Counter.class")
      fb_hover(c, "self.make\n").not_nil!.should contain("self : Counter.class")
    end
  end
end

describe "self in type bodies" do
  it "completes class methods on self outside defs" do
    src = "class Counter\n  def self.make : Counter\n    new\n  end\n\n  def bump : Int32\n    1\n  end\n\n  x = self.\nend\n"
    c = FeatureClient.new({"src/s.cr" => src}, PRELUDE_FILES)
    uri = c.open("src/s.cr")
    res = c.request("textDocument/completion", {textDocument: {uri: uri}, position: {line: 9, character: 11}})
    labels = res["items"].as_a.map(&.["label"].as_s)
    labels.should contain("make")
    labels.should_not contain("bump")
  ensure
    c.try(&.cleanup)
  end
end

HOVER_GAPS_APP = {
  "src/g.cr" => <<-CR,
    enum Color
      Red
    end

    module Shape
      abstract def area(scale : Int32) : Int32
    end

    struct Point
      property x : Int32 = 0
    end

    def run(t : {Int32, String}, c : Color)
      first, second = t
      pr = ->(v : Int32) { v + 1 }
      w = pr.call(1)
      q = c.red?
      b = 1_u8
      nt = {name: "n"}
      i = 0
      i += 1
    end
    CR
}

private def gap_hover(c, needle, shift = 0) : String?
  u = c.open("src/g.cr")
  h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/g.cr", needle, shift)})
  h.raw.nil? ? nil : h["contents"]["value"].as_s
end

describe "hover coverage gaps" do
  it "hovers inferred but previously unhandled positions" do
    with_client(HOVER_GAPS_APP, PRELUDE_FILES) do |c|
      gap_hover(c, "first,").not_nil!.should contain("first : Int32")
      gap_hover(c, "second =").not_nil!.should contain("second : String")
      gap_hover(c, "call(1)").not_nil!.should contain("call : Int32")
      gap_hover(c, "w =").not_nil!.should contain("w : Int32")
      gap_hover(c, "red?").not_nil!.should contain("red? : Bool")
      gap_hover(c, "q =").not_nil!.should contain("q : Bool")
      gap_hover(c, "1_u8").not_nil!.should contain("UInt8")
      gap_hover(c, "name:").not_nil!.should contain("name : String")
      gap_hover(c, "+= 1").not_nil!.should contain("+= : Int32")
      gap_hover(c, "scale :").not_nil!.should contain("scale : Int32")
      gap_hover(c, "property").not_nil!.should contain("def Point#x() : Int32")
      gap_hover(c, "property").not_nil!.should contain("def Point#x=(x : Int32)")
    end
  end
end

RETURN_APP = {
  "src/r.cr" => <<-CR,
    class Item
      getter name : String
      def initialize(@name)
      end
      def label
        name + "!"
      end
      def count(xs : Array(String))
        xs.size
      end
      def raw(x)
        x
      end
      def done : Nil
      end
    end
    CR
}

describe "inferred return types" do
  it "shows inferred returns in hover and inlay hints" do
    with_client(RETURN_APP, PRELUDE_FILES) do |c|
      u = c.open("src/r.cr")
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/r.cr", "label")})
      h["contents"]["value"].as_s.should contain("→ `String` (inferred)")
      hints = c.request("textDocument/inlayHint", {textDocument: {uri: u}, range: {start: {line: 0, character: 0}, end: {line: 20, character: 0}}})
      got = hints.as_a.map { |x| {x["position"]["line"].as_i, x["label"].as_s} }
      got.should contain({4, " : String"})
      got.should contain({7, " : Int32"})
      # After the closing paren of `def count(xs : Array(String))`, and after
      # the name when there are no parens.
      chars = hints.as_a.to_h { |x| {x["position"]["line"].as_i, x["position"]["character"].as_i} }
      chars[7].should eq "  def count(xs : Array(String))".size
      chars[4].should eq "  def label".size
      got.map(&.[0]).should_not contain(10) # raw(x): unknown
      got.map(&.[0]).should_not contain(13) # declared
      got.map(&.[0]).should_not contain(2)  # initialize
    end
  end
end
