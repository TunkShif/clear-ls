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
      hover18(c, "n = ").not_nil!.should start_with("```crystal\nn : UInt32\n```")
      hover18(c, "len = ").not_nil!.should start_with("```crystal\nlen : UInt32\n```")
    end
  end
end
