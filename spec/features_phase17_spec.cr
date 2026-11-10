require "./support/feature_client"
require "./support/prelude"

# Phase 17: annotations.

private STD = PRELUDE_FILES.merge({
  "annotations.cr" => <<-CR,
    # Marks enum members as bit flags.
    annotation Flags
    end

    # Links a lib.
    annotation Link
    end
    CR
  "file.cr" => <<-CR,
    class File
      @[Flags]
      enum Flags
        A
      end
    end
    struct Int
      alias Primitive = Int8
    end
    CR
})

private APP = {
  "src/app.cr" => <<-CR,
    annotation MyAnn
    end

    @[Link("m", ldflags: "-lm")]
    lib LibM
      @[Raises]
      fun cos(x : Float64) : Float64
    end

    @[MyAnn]
    @[AlwaysInline]
    def fast; end

    class File
      @[Flags]
      enum Mode
        A
      end

      @[Primitive(:x)]
      def prim; end
    end

    module Own
      annotation Raises
      end

      @[Raises]
      def own; end
    end
    CR
}

private def hover_text(c : FeatureClient, needle : String, shift = 0) : String?
  u = c.uri("src/app.cr")
  r = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", needle, shift)})
  r["contents"]?.try(&.["value"].as_s)
end

private def defs(c : FeatureClient, needle : String, shift = 0) : Array({String, Int32})
  u = c.uri("src/app.cr")
  r = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", needle, shift)})
  r.as_a.map { |l| {l["uri"].as_s.split('/').last, l["range"]["start"]["line"].as_i + 1} }
end

describe "phase 17 built-in annotations" do
  it "hovers annotations the compiler declares without source" do
    with_client(APP, STD) do |c|
      c.open("src/app.cr")
      h = hover_text(c, "Raises]\n  fun").not_nil!
      h.should start_with("```crystal\nannotation Raises\n```")
      h.should contain("Applies to: `fun`")
      h.should contain("no source declaration")
      hover_text(c, "AlwaysInline]").not_nil!.should contain("annotation AlwaysInline")
      defs(c, "AlwaysInline]").should be_empty
    end
  end

  it "keeps the source doc of a declared one and adds its arguments" do
    with_client(APP, STD) do |c|
      c.open("src/app.cr")
      h = hover_text(c, "Link(").not_nil!
      h.should contain("Links a lib.")
      h.should contain("`pkg_config : String`")
      h.should contain("`lib : String` — library name: looked up with `pkg-config`, else passed as `-l` (also positional #1)")
      defs(c, "Link(").should eq [{"annotations.cr", 6}]
    end
  end

  it "resolves Flags and Primitive at the top level, as the compiler does" do
    with_client(APP, STD) do |c|
      c.open("src/app.cr")
      # Inside `class File`, `Flags` would be the enum `File::Flags`.
      hover_text(c, "Flags]\n  enum Mode").not_nil!.should contain("annotation Flags")
      defs(c, "Flags]\n  enum Mode").should eq [{"annotations.cr", 2}]
      # `Int::Primitive` is not in scope here, but the top level wins anyway.
      hover_text(c, "Primitive(:x)").not_nil!.should contain("annotation Primitive")
    end
  end

  it "lets a declared annotation in scope win over a built-in name" do
    with_client(APP, STD) do |c|
      c.open("src/app.cr")
      h = hover_text(c, "Raises]\n  def own").not_nil!
      h.should contain("annotation Own::Raises")
      h.should_not contain("built into the compiler")
      defs(c, "Raises]\n  def own").should eq [{"app.cr", 25}]
    end
  end

  it "leaves user annotations alone" do
    with_client(APP, STD) do |c|
      c.open("src/app.cr")
      hover_text(c, "MyAnn]").not_nil!.should eq "```crystal\nannotation MyAnn\n```"
    end
  end
end
