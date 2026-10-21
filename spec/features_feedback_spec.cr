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
        @count
      end

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
    end
  end
end
