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
  r.as_h?.try(&.["contents"]?).try(&.["value"].as_s)
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

private ANN_STD = STD.merge({
  "json.cr" => <<-CR,
    module JSON
      annotation Field
      end

      # `JSON::Serializable`
      #
      # `JSON::Field` properties:
      # * **key**: the value of the key
      # * **emit_null**: if `true`, emits a `null` value
      #
      # ### Class annotation `JSON::Serializable::Options`
      #
      # supported properties:
      # * **emit_nulls**: if `true`, emits nulls for all
      module Serializable
        annotation Options
        end
      end

      # A field with its own doc.
      #
      # * **name**: the name
      annotation Named
      end

      class Lexer
      end
    end
    CR
  "path.cr" => "struct Path\nend\nclass Thread\nend\nmodule LibC\nend\n",
})

# Completion labels at `‸` in *text* (as `src/app.cr`).
private def labels_at(text : String) : Array({String, Int64})
  cur = text.index!('‸')
  line = text[0, cur].count('\n')
  col = cur - (text.rindex('\n', cur - 1).try(&.+(1)) || 0)
  with_client({"src/app.cr" => text.sub("‸", "")}, ANN_STD) do |c|
    u = c.open("src/app.cr")
    r = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: line, character: col}})
    r["items"].as_a.map { |i| {i["label"].as_s, i["kind"].as_i64} }.sort
  end
end

private def names(text : String) : Array(String)
  labels_at(text).map(&.[0])
end

private BUILTIN_NAMES = IDE::Annotations::BUILTINS.map(&.name)

describe "phase 17 annotation name completion" do
  it "offers only annotations after `@[`" do
    got = names("annotation MyAnn\nend\n\n@[‸\ndef f; end\n")
    got.should contain("MyAnn")
    got.should contain("AlwaysInline")
    got.should contain("JSON") # holds JSON::Field
    got.should_not contain("Path")
    got.should_not contain("Thread")
    got.should_not contain("LibC")
    got.should_not contain("puts")
    (got - BUILTIN_NAMES - ["MyAnn", "JSON"]).should be_empty
    BUILTIN_NAMES.each { |n| got.should contain(n) }
  end

  it "uses the annotation completion kind (8, interface)" do
    labels_at("@[Ra‸\ndef f; end\n").should eq [{"Raises", 8_i64}]
  end

  it "filters by the typed prefix" do
    names("@[Li‸\nlib L\nend\n").should eq ["Link"]
    names("@[Pa‸\nstruct S\nend\n").should eq ["Packed"]
    names("@[‸]\ndef f; end\n").should contain("Deprecated")
  end

  it "completes inside a path" do
    labels_at("@[JSON::‸\ndef f; end\n").should eq [{"Field", 8_i64}, {"Named", 8_i64}, {"Serializable", 9_i64}]
    names("@[JSON::Serializable::‸\ndef f; end\n").should eq ["Options"]
    names("@[::Li‸\nlib L\nend\n").should eq ["Link"]
  end

  it "works in a class body, before a fun, after another annotation" do
    names("class C\n  @[Dep‸\n  def f; end\nend\n").should eq ["Deprecated"]
    names("lib L\n  @[Rai‸\n  fun f : Int32\nend\n").should eq ["Raises"]
    names("@[Link(\"a]b\")] @[Li‸\nlib L\nend\n").should eq ["Link"]
  end

  it "includes annotations of enclosing namespaces" do
    names("module Outer\n  annotation Mine\n  end\n\n  class C\n    @[Mi‸\n    def f; end\n  end\nend\n").should eq ["Mine"]
  end

  it "stays out of strings and comments" do
    names("x = \"@[‸\"\n").should_not contain("AlwaysInline")
    names("# @[‸\ndef f; end\n").should_not contain("AlwaysInline")
  end
end

private def arg_labels(text : String) : Array(String)
  labels_at(text).map(&.[0])
end

describe "phase 17 annotation arguments" do
  it "completes a built-in's named arguments" do
    got = arg_labels("@[Link(‸\nlib L\nend\n")
    got.should eq %w(dll: framework: ldflags: lib: pkg_config: static: wasm_import_module:)
    arg_labels("@[Link(\"m\", pk‸\nlib L\nend\n").should eq ["pkg_config:"]
    arg_labels("@[Extern(‸\nstruct S\nend\n").should eq ["union:"]
    arg_labels("@[TargetFeature(\"+avx2\", ‸\ndef f; end\n").should eq ["cpu:"]
  end

  it "skips arguments written by name or by position" do
    got = arg_labels("@[Link(\"m\", \"-lx\", pkg_config: \"m\", ‸\nlib L\nend\n")
    got.should_not contain("lib:")
    got.should_not contain("ldflags:")
    got.should_not contain("pkg_config:")
    got.should contain("static:")
  end

  it "inserts `name: ` over the typed word" do
    with_client({"src/app.cr" => "@[Link(pk\nlib L\nend\n"}, ANN_STD) do |c|
      u = c.open("src/app.cr")
      i = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: 0, character: 9}})["items"].as_a.first
      i["label"].should eq "pkg_config:"
      i["textEdit"]["newText"].should eq "pkg_config: "
      i["textEdit"]["range"]["start"]["character"].should eq 7
      i["filterText"].should eq "pkg_config"
    end
  end

  it "reads the stdlib's property bullets" do
    arg_labels("@[JSON::Field(‸\ndef f; end\n").should eq %w(emit_null: key:)
    arg_labels("@[JSON::Field(key: \"a\", ‸\ndef f; end\n").should eq %w(emit_null:)
    arg_labels("@[JSON::Serializable::Options(‸\nclass A\nend\n").should eq %w(emit_nulls:)
    arg_labels("@[JSON::Named(‸\ndef f; end\n").should eq %w(name:)
  end

  it "leaves annotations without known arguments alone" do
    arg_labels("annotation Mine\nend\nx = 1\n@[Mine(‸\ndef f; end\n").should contain("x")
    arg_labels("@[Link(lib: \"m\", ldflags: \"x\", static: false, framework: \"F\", pkg_config: \"p\", wasm_import_module: \"w\", dll: \"d.dll\", ‸\nlib L\nend\n").should be_empty
  end

  it "hovers argument names and positional values" do
    files = {"src/app.cr" => "@[Link(\"m\", ldflags: \"-lm\")]\nlib L\nend\n\n@[JSON::Field(key: \"k\")]\ndef f; end\n\n@[Deprecated(\"use g\")]\ndef g; end\n"}
    with_client(files, ANN_STD) do |c|
      c.open("src/app.cr")
      h = hover_text(c, "ldflags").not_nil!
      h.should start_with("```crystal\nldflags : String\n```\n\nargument of `Link`")
      h.should contain("passed to the linker as is")
      hover_text(c, "\"m\"", 1).not_nil!.should contain("lib : String\n```\n\nargument of `Link` (positional #1)")
      hover_text(c, "key:").not_nil!.should eq "```crystal\nkey\n```\n\nargument of `JSON::Field`\n\nthe value of the key"
      hover_text(c, "\"use g\"", 1).not_nil!.should contain("message : String")
      hover_text(c, "\"-lm\"", 1).should be_nil # a value, not the name
    end
  end
end

describe "phase 17 `[` trigger" do
  it "is a trigger character that answers only after `@`" do
    with_client({"src/app.cr" => "@[\nxs = [1]\nxs[\n"}, ANN_STD) do |c|
      c.init_result["capabilities"]["completionProvider"]["triggerCharacters"].as_a.should contain("[")
      u = c.open("src/app.cr")
      ask = ->(line : Int32, col : Int32, ctx : NamedTuple(triggerKind: Int32, triggerCharacter: String) | NamedTuple(triggerKind: Int32)) do
        c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: line, character: col}, context: ctx})["items"].as_a.map(&.["label"].as_s)
      end
      ask.call(0, 2, {triggerKind: 2, triggerCharacter: "["}).should contain("Link")
      ask.call(2, 3, {triggerKind: 2, triggerCharacter: "["}).should be_empty
      ask.call(2, 3, {triggerKind: 1}).should contain("xs")
    end
  end
end

describe IDE::AnnotationContext do
  it "tells the name from the arguments" do
    ctx = IDE::AnnotationContext.at("@[JSON::Fi", 10_u32).as(IDE::AnnotationContext::Name)
    {ctx.qualifier, ctx.prefix, ctx.start}.should eq({"JSON", "Fi", 8_u32})
    text = "@[Link(\"m\", ldflags: \"x, y\", pk"
    args = IDE::AnnotationContext.at(text, text.bytesize.to_u32).as(IDE::AnnotationContext::Args)
    {args.name, args.prefix, args.written, args.positional}.should eq({"Link", "pk", ["ldflags"], 1})
  end

  it "is nil once the annotation is closed or inside a value" do
    IDE::AnnotationContext.at("@[Link] x", 9_u32).should be_nil
    IDE::AnnotationContext.at("@[Link(\"ab", 10_u32).should be_nil
    IDE::AnnotationContext.at("@[Link(ldflags: \"a", 18_u32).should be_nil
  end
end
