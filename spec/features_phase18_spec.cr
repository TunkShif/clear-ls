require "./support/feature_client"
require "./support/prelude"

# Phase 18: C bindings.

private STD = PRELUDE_FILES.merge({
  "lib_c.cr" => <<-CR,
    struct UInt32 < Int; end

    lib LibC
      alias Int = Int32
      alias UInt = UInt32
    end
    CR
  # `require "c/..."` resolves under lib_c/<arch>-<os> (the spec
  # project's target is x86_64-unknown-linux-gnu).
  "lib_c/x86_64-linux-gnu/c/stdint.cr" => <<-CR,
    lib LibC
      alias UInt32T = UInt
    end
    CR
  "lib_c/x86_64-linux-gnu/c/string.cr" => <<-CR,
    require "./stdint"

    lib LibC
      fun strlen(s : UInt8*) : UInt32T
    end
    CR
  "lib_c/aarch64-darwin/c/stdint.cr" => "lib LibC\n  alias UInt32T = UInt64\nend\n",
})

private APP = {
  "src/app.cr" => <<-CR,
    require "c/string"

    lib LibX
      fun count(x : Int32) : LibC::UInt32T
    end

    def run
      n = LibX.count(1)
      len = LibC.strlen("a")
      n
    end
    CR
}

private def hover18(c : FeatureClient, needle : String, shift = 0) : String?
  u = c.uri("src/app.cr")
  r = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", needle, shift)})
  r.as_h?.try(&.["contents"]?).try(&.["value"].as_s)
end

private def def_paths(c : FeatureClient, needle : String, shift = 0) : Array({String, Int32})
  u = c.uri("src/app.cr")
  r = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", needle, shift)})
  # The last three path segments: `lib_c/<target>/c/x.cr` stays telling.
  r.as_a.map { |l| {l["uri"].as_s.split('/').last(4).join('/'), l["range"]["start"]["line"].as_i + 1} }
end

describe "phase 18 lib_c target path" do
  it "resolves `c/...` requires and LibC target types" do
    with_client(APP, STD) do |c|
      c.open("src/app.cr")
      def_paths(c, "c/string", 1).should eq [{"lib_c/x86_64-linux-gnu/c/string.cr", 1}]
      hover18(c, "UInt32T").not_nil!.should start_with("```crystal\nalias LibC::UInt32T = UInt\n```")
      def_paths(c, "UInt32T").should eq [{"lib_c/x86_64-linux-gnu/c/stdint.cr", 2}]
    end
  end

  it "types C calls whose return types are target types" do
    with_client(APP, STD) do |c|
      c.open("src/app.cr")
      # Written as the alias in the fun's declaration; the target type below.
      hover18(c, "n = ").not_nil!.should eq "```crystal\nn : LibC::UInt32T\n```\n\nlocal variable\n\n= `UInt32`"
      hover18(c, "len = ").not_nil!.should contain("= `UInt32`")
    end
  end
end

private FFI = {
  "src/app.cr" => <<-CR,
    lib LibM
      # Cosine.
      fun cos(x : Float64) : Float64
      fun printf(fmt : UInt8*, ...) : Int32
      fun my_open = "open"(path : UInt8*, flags : Int32) : Int32
      $errno : Int32

      struct Point
        x : Int32
        y : Int32
      end
    end

    lib LibM
      fun sin(x : Float64) : Float64
    end

    def run
      a = LibM.cos(1.0)
      LibM.printf("%d", 1, 2)
      LibM.my_open("p", 0)
      e = LibM.errno
      pt = LibM::Point.new
      pt.x
      pt.y = 3
      LibM.sin(a)
    end
    CR
}

private def ffi_hover(c : FeatureClient, needle : String, shift = 0) : String?
  u = c.uri("src/app.cr")
  r = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", needle, shift)})
  r.as_h?.try(&.["contents"]?).try(&.["value"].as_s)
end

private def ffi_lines(c : FeatureClient, method : String, needle : String, shift = 0, extra = {} of String => String) : Array(Int32)
  u = c.uri("src/app.cr")
  params = {textDocument: {uri: u}, position: c.pos("src/app.cr", needle, shift), context: {includeDeclaration: true}}
  c.request(method, params).as_a.map { |l| l["range"]["start"]["line"].as_i + 1 }.sort
end

private def ffi_complete(text_line : String) : Array({String, Int64, String?})
  src = FFI["src/app.cr"].sub("  LibM.sin(a)\n", "  LibM.sin(a)\n#{text_line}\n")
  with_client({"src/app.cr" => src}, STD) do |c|
    u = c.open("src/app.cr")
    line = src.lines.index!(text_line)
    r = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: line, character: text_line.size}})
    r["items"].as_a.map { |i| {i["label"].as_s, i["kind"].as_i64, i["detail"]?.try(&.as_s)} }
  end
end

describe "phase 18 C calls navigate like methods" do
  it "hovers funs, globals and fields at their uses" do
    with_client(FFI, STD) do |c|
      c.open("src/app.cr")
      ffi_hover(c, "cos(1.0)").not_nil!.should eq "```crystal\nfun LibM.cos(x : Float64) : Float64\n```\n\n→ `Float64`\n\nCosine."
      ffi_hover(c, "printf(\"").not_nil!.should start_with("```crystal\nfun LibM.printf(fmt : UInt8*, ...) : Int32\n```")
      ffi_hover(c, "my_open(\"").not_nil!.should contain("C name: `open`")
      ffi_hover(c, "errno\n").not_nil!.should eq "```crystal\nLibM.errno : Int32\n```\n\nC global variable `$errno`"
      ffi_hover(c, "x\n  pt.y").not_nil!.should eq "```crystal\nLibM::Point#x : Int32\n```\n\nstruct field"
    end
  end

  it "goes to the declaration, including another `lib` reopening" do
    with_client(FFI, STD) do |c|
      c.open("src/app.cr")
      ffi_lines(c, "textDocument/definition", "cos(1.0)").should eq [3]
      ffi_lines(c, "textDocument/definition", "errno\n").should eq [6]
      ffi_lines(c, "textDocument/definition", "y = 3").should eq [10]
      ffi_lines(c, "textDocument/definition", "sin(a)").should eq [15]
    end
  end

  it "finds references from a use or the declaration, setters included" do
    with_client(FFI, STD) do |c|
      c.open("src/app.cr")
      ffi_lines(c, "textDocument/references", "cos(x").should eq [3, 19]
      ffi_lines(c, "textDocument/references", "cos(1.0)").should eq [3, 19]
      ffi_lines(c, "textDocument/references", "y : Int32").should eq [10, 25]
      ffi_lines(c, "textDocument/references", "errno : Int32").should eq [6, 22]
    end
  end

  it "renames a fun at every use" do
    with_client(FFI, STD) do |c|
      u = c.open("src/app.cr")
      r = c.request("textDocument/rename", {textDocument: {uri: u}, position: c.pos("src/app.cr", "cos(1.0)"), newName: "cosine"})
      r["changes"][u].as_a.map { |e| e["range"]["start"]["line"].as_i + 1 }.sort.should eq [3, 19]
    end
  end

  it "gives signature help, `...` for variadic funs" do
    with_client({"src/app.cr" => FFI["src/app.cr"].sub("  LibM.sin(a)\n", "  LibM.sin(a)\n  LibM.printf(\"x\", \n")}, STD) do |c|
      u = c.open("src/app.cr")
      line = c.pos("src/app.cr", "LibM.printf(\"x\", ")[:line]
      r = c.request("textDocument/signatureHelp", {textDocument: {uri: u}, position: {line: line, character: 19}})
      r["signatures"][0]["label"].should eq "printf(fmt : UInt8*, ...) : Int32"
    end
  end

  it "completes funs and globals after `LibM.`, fields after a struct value" do
    got = ffi_complete("  LibM.")
    got.map(&.[0]).should eq %w(cos errno my_open printf sin)
    got.find! { |i| i[0] == "cos" }.should eq({"cos", 3_i64, "cos(x : Float64) : Float64"})
    got.find! { |i| i[0] == "errno" }.should eq({"errno", 6_i64, "errno : Int32"})
    ffi_complete("  pt.").should eq [{"x", 5_i64, "x : Int32"}, {"y", 5_i64, "y : Int32"}]
  end
end

describe "phase 18 C declaration hover" do
  it "hovers fun, global and field names where they are declared" do
    src = FFI["src/app.cr"].sub("    x : Int32\n", "    x, z : Int32\n")
    with_client({"src/app.cr" => src}, STD) do |c|
      c.open("src/app.cr")
      ffi_hover(c, "cos(x").not_nil!.should eq "```crystal\nfun LibM.cos(x : Float64) : Float64\n```\n\nCosine."
      ffi_hover(c, "my_open =").not_nil!.should contain("C name: `open`")
      ffi_hover(c, "errno : Int32").not_nil!.should eq "```crystal\nLibM.errno : Int32\n```\n\nC global variable `$errno`"
      ffi_hover(c, "z : Int32").not_nil!.should eq "```crystal\nLibM::Point#z : Int32\n```\n\nstruct field"
      ffi_hover(c, "x, z").not_nil!.should eq "```crystal\nLibM::Point#x : Int32\n```\n\nstruct field"
    end
  end

  it "hovers fun parameters" do
    with_client(FFI, STD) do |c|
      c.open("src/app.cr")
      ffi_hover(c, "x : Float64) : Float64\n  fun printf").not_nil!.should eq "```crystal\nx : Float64\n```\n\nparameter"
      ffi_hover(c, "flags").not_nil!.should eq "```crystal\nflags : Int32\n```\n\nparameter"
    end
  end
end
