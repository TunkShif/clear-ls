require "./spec_helper"
require "./support/feature_client"
require "./support/prelude"

private def hover_text(c, path, needle, shift = 0) : String
  u = c.open(path)
  h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos(path, needle, shift)})
  h.raw.nil? ? "nil" : h["contents"]["value"].as_s
end

describe "file-level namespace" do
  it "does not treat top-level code as inside a type declared first" do
    files = {"src/a.cr" => <<-CR}
      module App
        class Item
        end
        X = Item.new
      end
      class Other
      end
      x = Item.new
      y = App::Item.new
      CR
    with_client(files, PRELUDE_FILES) do |c|
      # `Item` is not visible at the top level (the compiler: undefined
      # constant Item); it was typed App::Item because the file starts
      # with `module App`.
      hover_text(c, "src/a.cr", "x = ").should contain("```crystal\nx\n```")
      hover_text(c, "src/a.cr", "y = ").should contain("y : App::Item")
      # Inside the module body the lookup still starts in App.
      d = c.request("textDocument/definition", {textDocument: {uri: c.uri("src/a.cr")}, position: c.pos("src/a.cr", "Item.new\nend", 0)})
      d.as_a.size.should eq 1
    end
  end
end

INCLUDE_APP = {
  "src/a.cr" => <<-CR,
    require "./lib"
    include Lib

    def helper_user
      w = Widget.new
      w.size
    end

    class Panel
      def show
        greet
      end
    end

    x = greet
    LIMIT
    CR
  "src/lib.cr" => <<-CR,
    module Lib
      LIMIT = 3

      class Widget
        def size : Int32
          1
        end
      end

      def greet : String
        "hi"
      end

      def self.only_on_module : Int32
        1
      end
    end
    CR
}

describe "top-level include" do
  it "makes the module's types, constants and methods visible everywhere" do
    with_client(INCLUDE_APP, PRELUDE_FILES) do |c|
      hover_text(c, "src/a.cr", "w = ").should contain("w : Lib::Widget")
      hover_text(c, "src/a.cr", "w.size", 2).should contain("def Lib::Widget#size")
      hover_text(c, "src/a.cr", "greet\n  end", 0).should contain("def Lib#greet() : String")
      hover_text(c, "src/a.cr", "x = ").should contain("x : String")
      hover_text(c, "src/a.cr", "\nLIMIT", 1).should contain("Lib::LIMIT = 3")
      u = c.uri("src/a.cr")
      d = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/a.cr", "x = greet", 4)})
      d.as_a.map(&.["uri"].as_s).should eq [c.uri("src/lib.cr")]
      # Completion of bare identifiers offers included methods.
      c.notify("textDocument/didChange", {textDocument: {uri: u, version: 2}, contentChanges: [{range: {start: {line: 15, character: 0}, end: {line: 15, character: 0}}, text: "gre\n"}]})
      r = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: 15, character: 3}})
      r["items"].as_a.map(&.["label"].as_s).should contain("greet")
    end
  end

  it "finds references through the include and keeps the edit a declaration change" do
    with_client(INCLUDE_APP, PRELUDE_FILES) do |c|
      u = c.open("src/lib.cr")
      r = c.request("textDocument/references", {textDocument: {uri: u}, position: c.pos("src/lib.cr", "def greet", 4), context: {includeDeclaration: true}})
      r.as_a.map { |x| "#{x["uri"].as_s.split("/").last}:#{x["range"]["start"]["line"].as_i + 1}" }.sort.should eq ["a.cr:11", "a.cr:15", "lib.cr:10"]
      # Removing the include is a declaration change: greet is unknown again.
      au = c.open("src/a.cr")
      rebuilds = c.server.index.rebuilds
      c.notify("textDocument/didChange", {textDocument: {uri: au, version: 2}, contentChanges: [{range: {start: {line: 1, character: 0}, end: {line: 1, character: 11}}, text: ""}]})
      h = c.request("textDocument/hover", {textDocument: {uri: au}, position: c.pos("src/a.cr", "x = ")})
      h["contents"]["value"].as_s.should contain("```crystal\nx\n```")
      c.server.index.rebuilds.should be > rebuilds
    end
  end

  it "resolves the spec DSL (include Spec::Methods in the prelude)" do
    spec_lib = {
      "spec.cr" => "module Spec::Methods\n  def describe(description, &block)\n  end\n  def it(description, &block)\n  end\nend\nmodule Spec::Expectations\n  def eq(value)\n    value\n  end\nend\ninclude Spec::Methods\ninclude Spec::Expectations\n",
    }
    # The fake stdlib's prelude requires spec.cr, like a program that
    # requires "spec".
    files = {"spec/x_spec.cr" => "describe \"x\" do\n  it \"y\" do\n    v = eq(1)\n  end\nend\n"}
    with_client(files, PRELUDE_FILES.merge(spec_lib)) do |c|
      hover_text(c, "spec/x_spec.cr", "describe").should contain("def Spec::Methods#describe")
      hover_text(c, "spec/x_spec.cr", "v = ").should contain("v : Int32")
    end
  end
end

ALIAS_APP = {
  "src/a.cr" => <<-CR,
    module Cfg
      alias Env = Hash(String, String)
    end
    alias Env2 = Cfg::Env

    def foo : Cfg::Env?
      e = Cfg::Env.new
      f = Env2.new
      nil
    end
    CR
}

describe "aliases at use sites" do
  it "go to the alias, not its target" do
    with_client(ALIAS_APP, PRELUDE_FILES) do |c|
      u = c.open("src/a.cr")
      defn = ->(needle : String, shift : Int32) do
        d = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/a.cr", needle, shift)})
        d.as_a.map { |x| x["range"]["start"]["line"].as_i + 1 }
      end
      defn.call("Cfg::Env?", 6).should eq [2]
      defn.call("Env2.new", 0).should eq [4]
      defn.call("Cfg::Env\n", 6).should eq [2] # an alias's own target
      hover_text(c, "src/a.cr", "Cfg::Env?", 6).should contain("alias Cfg::Env = Hash(String, String)")
      # Inference still sees through: `Cfg::Env.new` is a Hash.
      hover_text(c, "src/a.cr", "e = ").should contain("e : Hash(String, String)")
      refs = c.request("textDocument/references", {textDocument: {uri: u}, position: c.pos("src/a.cr", "alias Env =", 6), context: {includeDeclaration: true}})
      refs.as_a.map { |x| x["range"]["start"]["line"].as_i + 1 }.should eq [2, 4, 6, 7]
    end
  end
end
