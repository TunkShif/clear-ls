require "./support/feature_client"
require "./support/prelude"

# Phase 19: clear-ls's own tree-sitter-crystal.

private def p19_hover(c : FeatureClient, needle : String, shift = 0) : String?
  u = c.uri("src/app.cr")
  r = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", needle, shift)})
  r.as_h?.try(&.["contents"]?).try(&.["value"].as_s)
end

private def p19_defs(c : FeatureClient, needle : String, shift = 0) : Array(Int32)
  u = c.uri("src/app.cr")
  r = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", needle, shift)})
  r.as_a.map { |l| l["range"]["start"]["line"].as_i + 1 }
end

describe "phase 19 grammar: self as a fun param (A1)" do
  it "lowers both params and types the call" do
    src = <<-CR
      lib LibTS
        enum SymbolType
          Regular
        end
        type Language = Void*
        fun symbol_type(self : Language*, symbol : UInt16) : SymbolType
      end

      def run(lang : LibTS::Language*)
        t = LibTS.symbol_type(lang, 1_u16)
      end
      CR
    tree = Syntax::Parser.new.parse(src)
    items = Items::Lower.lower(tree)
    items.recovered.should be_false
    fun_item = items.items[0].children.find! { |i| i.kind.fun? }
    fun_item.signature.not_nil!.params.map { |p| {p.name, p.restriction} }.should eq [{"self", "Language*"}, {"symbol", "UInt16"}]
    with_client({"src/app.cr" => src}, PRELUDE_FILES) do |c|
      c.open("src/app.cr")
      p19_hover(c, "symbol_type(lang").not_nil!.should start_with("```crystal\nfun LibTS.symbol_type(self : Language*, symbol : UInt16) : SymbolType\n```")
      p19_hover(c, "t = ").not_nil!.should start_with("```crystal\nt : LibTS::SymbolType\n```")
      p19_defs(c, "symbol_type(lang").should eq [6]
    end
  end
end

describe "phase 19 grammar: short-block assignment (A2)" do
  src = <<-CR
    class Conn
      property name : String = ""
      property count : Int32 = 0
    end

    def run(c : Conn?, cs : Array(Conn))
      c.try &.name = "x"
      cs.each &.count += 1
      cs.each(&.name=("y"))
    end
    CR

  it "parses without errors and lowers the setter call" do
    tree = Syntax::Parser.new.parse(src)
    tree.root.has_error?.should be_false
  end

  it "resolves, references and renames the setter through `&.x = v`" do
    with_client({"src/app.cr" => src}, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      p19_hover(c, "name = \"x\"").not_nil!.should start_with("```crystal\ndef Conn#name=(name : String)\n```")
      p19_defs(c, "name = \"x\"").should eq [2]
      p19_defs(c, "count += 1").should eq [3]
      refs = c.request("textDocument/references", {textDocument: {uri: u}, position: c.pos("src/app.cr", "name : String"), context: {includeDeclaration: true}})
      refs.as_a.map { |l| l["range"]["start"]["line"].as_i + 1 }.sort.should eq [2, 7, 9]
      r = c.request("textDocument/rename", {textDocument: {uri: u}, position: c.pos("src/app.cr", "name : String"), newName: "title"})
      r["changes"][u].as_a.map { |e| e["range"]["start"]["line"].as_i + 1 }.sort.should eq [2, 7, 9]
    end
  end
end
