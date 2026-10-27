require "./support/feature_client"

include ClearLS
include ClearLS::LSP

APP = {
  "shard.yml"          => "name: app\n",
  "src/app.cr"         => <<-CR,
    require "./models/*"
    require "dep"

    # The application.
    module App
      VERSION = "1.0"

      class Service < Dep::Base
        include Dep::Helpers

        def run(x : Models::User) : Nil
          Models::User::ROLE
        end
      end
    end
    CR
  "src/models/user.cr" => <<-CR,
    module App::Models
      # A user account.
      class User
        ROLE = :admin
        getter name : String

        def initialize(@name)
        end
      end
    end
    CR
  "lib/dep/src/dep.cr" => <<-CR,
    module Dep
      # Base class from a shard.
      abstract class Base
      end

      module Helpers
      end
    end
    CR
}

describe "LSP features" do
  it "advertises phase 1 capabilities" do
    with_client(APP) do |c|
      c.server.index.size.should eq 3
    end
  end

  it "returns nested document symbols" do
    with_client(APP) do |c|
      syms = c.request("textDocument/documentSymbol", {textDocument: {uri: c.uri("src/models/user.cr")}})
      mod = syms[0]
      mod["name"].should eq "App::Models"
      user = mod["children"][0]
      user["name"].should eq "User"
      user["kind"].should eq 5
      user["children"].as_a.map(&.["name"].as_s).should eq ["ROLE", "name", "initialize"]
      user["selectionRange"]["start"].should eq JSON.parse(%({"line":2,"character":8}))
    end
  end

  it "finds workspace symbols, project files first" do
    with_client(APP) do |c|
      res = c.request("workspace/symbol", {query: "base"})
      res.as_a.map(&.["name"].as_s).should eq ["Base"]
      res[0]["containerName"].should eq "Dep"
      user = c.request("workspace/symbol", {query: "User"}).as_a.find! { |s| s["name"] == "User" }
      user["containerName"].should eq "App::Models"
      res[0]["location"]["uri"].should eq c.uri("lib/dep/src/dep.cr")
      c.request("workspace/symbol", {query: "usr"}).as_a.map(&.["name"].as_s).should contain("User")
    end
  end

  it "goes to type definitions across files and shards" do
    with_client(APP) do |c|
      u = c.open("src/app.cr")
      # `Dep::Base` superclass → shard file.
      defs = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", "Base")})
      defs[0]["uri"].should eq c.uri("lib/dep/src/dep.cr")
      defs[0]["range"]["start"]["line"].should eq 2
      # Cursor on `Dep` of `Dep::Base` resolves only the prefix.
      defs = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", "Dep::Base")})
      defs[0]["range"]["start"]["line"].should eq 0
      # Relative path from inside App::Service resolves through App.
      defs = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", "User)")})
      defs[0]["uri"].should eq c.uri("src/models/user.cr")
      # Constants.
      defs = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", "ROLE")})
      defs[0]["range"]["start"]["line"].should eq 3
    end
  end

  it "goes to required files" do
    with_client(APP) do |c|
      u = c.open("src/app.cr")
      defs = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", "dep\"")})
      defs[0]["uri"].should eq c.uri("lib/dep/src/dep.cr")
      links = c.request("textDocument/documentLink", {textDocument: {uri: u}})
      links.as_a.map(&.["target"].as_s).should eq [c.uri("src/models"), c.uri("lib/dep/src/dep.cr")]
    end
  end

  it "lists every file of a glob require" do
    with_client({
      "src/app.cr"      => "require \"./models/*\"\nrequire \"./one\"\n",
      "src/one.cr"      => "",
      "src/models/a.cr" => "",
      "src/models/b.cr" => "",
    }) do |c|
      u = c.open("src/app.cr")
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "models")})
      h["contents"]["value"].as_s.should eq "```\nmodels/a.cr\nmodels/b.cr\n```\n\n2 files"
      defs = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", "models")})
      defs.as_a.map(&.["uri"].as_s).should eq [c.uri("src/models/a.cr"), c.uri("src/models/b.cr")]
      # A single file keeps the absolute-path hover.
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "one")})
      h["contents"]["value"].as_s.should eq "```\n#{File.join(c.root, "src/one.cr")}\n```"
      links = c.request("textDocument/documentLink", {textDocument: {uri: u}})
      links.as_a.map(&.["target"].as_s).should eq [c.uri("src/models"), c.uri("src/one.cr")]
    end
  end

  it "hovers types with signature and doc" do
    with_client(APP) do |c|
      u = c.open("src/app.cr")
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "User)")})
      h["contents"]["value"].as_s.should eq "```crystal\nclass App::Models::User\n```\n\nA user account."
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "Base")})
      h["contents"]["value"].as_s.should contain("abstract class Dep::Base")
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "VERSION")})
      h["contents"]["value"].as_s.should contain(%(App::VERSION = "1.0"))
    end
  end

  it "folds blocks and comment runs and nests selection ranges" do
    with_client(APP) do |c|
      u = c.open("src/app.cr")
      folds = c.request("textDocument/foldingRange", {textDocument: {uri: u}}).as_a
      folds.map { |f| {f["startLine"].as_i, f["endLine"].as_i} }.should contain({4, 13})
      sel = c.request("textDocument/selectionRange", {textDocument: {uri: u}, positions: [c.pos("src/app.cr", "ROLE")]})
      depth = 0
      node = sel[0]
      while node
        depth += 1
        node = node["parent"]?
      end
      depth.should be > 4
    end
  end

  it "keeps answers current after edits" do
    with_client(APP) do |c|
      u = c.open("src/models/user.cr")
      c.notify("textDocument/didChange", {
        textDocument:   {uri: u, version: 2},
        contentChanges: [{range: {start: {line: 2, character: 8}, end: {line: 2, character: 12}}, text: "Account"}],
      })
      c.server.index.def_map.lookup_path("App::Models::Account").should_not be_nil
      c.server.index.def_map.lookup_path("App::Models::User").should be_nil
      c.notify("textDocument/didClose", {textDocument: {uri: u}})
      c.server.index.def_map.lookup_path("App::Models::User").should_not be_nil
    end
  end
end

describe "workspace scope" do
  files = {
    "shard.yml"            => "name: app\ntargets:\n  app:\n    main: src/app.cr\n",
    "src/app.cr"           => "require \"./item\"\nItem.new\n",
    "src/item.cr"          => "class Item\nend\n",
    "scripts/tool.cr"      => "require \"../src/item\"\nclass Helper\nend\nItem.new\n",
    "examples/other/shard.yml" => "name: other\n",
    "examples/other/src/o.cr"  => "class Item\nend\nclass Other\nend\nItem.new\n",
  }

  it "gives each program its own declarations" do
    with_client(files) do |c|
      u = c.open("src/app.cr")
      d = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", "Item.new")})
      d.as_a.map(&.["uri"].as_s).should eq [c.uri("src/item.cr")]
      # The nested project and the script are not part of the program.
      c.server.index.def_map.lookup_path("Other").should be_nil
      c.server.index.def_map.lookup_path("Helper").should be_nil
      # The script sees what it requires.
      su = c.open("scripts/tool.cr")
      d = c.request("textDocument/definition", {textDocument: {uri: su}, position: c.pos("scripts/tool.cr", "Item.new")})
      d.as_a.map(&.["uri"].as_s).should eq [c.uri("src/item.cr")]
      # The nested project sees its own `Item` only.
      ou = c.open("examples/other/src/o.cr")
      d = c.request("textDocument/definition", {textDocument: {uri: ou}, position: c.pos("examples/other/src/o.cr", "Item.new")})
      d.as_a.map(&.["uri"].as_s).should eq [c.uri("examples/other/src/o.cr")]
    end
  end

  it "keeps loose files apart when there is no project" do
    with_client({"a.cr" => "class Item\nend\nItem.new\n", "b.cr" => "class Item\nend\n"}) do |c|
      u = c.open("a.cr")
      d = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("a.cr", "Item.new")})
      d.as_a.map(&.["uri"].as_s).should eq [c.uri("a.cr")]
    end
  end

  it "finds the project above a client root inside it" do
    with_project_root = File.tempname("clear-ls-scope")
    Dir.mkdir_p(File.join(with_project_root, "src/sub"))
    File.write(File.join(with_project_root, "shard.yml"), "name: x\n")
    begin
      server = Server.new(Transport.new(IO::Memory.new, IO::Memory.new))
      server.project_factory = ->(root : String) { Workspace::Project.new(root, ["lib"], nil, nil, "x86_64-unknown-linux-gnu") }
      server.dispatch({jsonrpc: "2.0", id: 1, method: "initialize", params: {rootUri: VFS.uri_for(File.join(with_project_root, "src/sub")), capabilities: {} of String => String}}.to_json)
      server.dispatch({jsonrpc: "2.0", method: "initialized", params: {} of String => String}.to_json)
      server.index.project.root.should eq with_project_root
    ensure
      FileUtils.rm_rf(with_project_root)
    end
  end
end

describe "spec program views" do
  files = {
    "shard.yml"                 => "name: app\ntargets:\n  app:\n    main: src/app.cr\n",
    "src/app.cr"                => "class App\nend\n",
    "spec/spec_helper.cr"       => "require \"../src/app\"\nrequire \"./support/fixture\"\n",
    "spec/support/fixture.cr"   => "class Fixture\nend\n",
    "spec/a/spec_helper.cr"     => "require \"../spec_helper\"\n",
    "spec/a/one_spec.cr"        => "require \"./spec_helper\"\nmodule OneSpec\n  class Helper\n  end\nend\nApp.new\n",
    "spec/two_spec.cr"          => "require \"./spec_helper\"\nOneSpec::Helper.new\nFixture.new\n",
    "scripts/tool.cr"           => "require \"../src/app\"\nOneSpec::Helper\n",
  }

  it "puts specs with one helper into one program" do
    with_client(files) do |c|
      one = c.open("spec/a/one_spec.cr")
      two = c.open("spec/two_spec.cr")
      idx = c.server.index
      id = ->(p : String) { c.server.vfs.id_for(c.uri(p)) }
      idx.def_map_for(id.call("spec/a/one_spec.cr")).should be(idx.def_map_for(id.call("spec/two_spec.cr")))
      # A spec sees another spec's helper types, like `crystal spec`.
      d = c.request("textDocument/definition", {textDocument: {uri: two}, position: c.pos("spec/two_spec.cr", "Helper")})
      d.as_a.map(&.["uri"].as_s).should eq [c.uri("spec/a/one_spec.cr")]
      # Support files required by the helper belong to that program.
      idx.def_map_for(id.call("spec/support/fixture.cr")).should be(idx.def_map_for(id.call("spec/two_spec.cr")))
      # Scripts don't see the specs; the project doesn't either.
      idx.def_map_for(id.call("scripts/tool.cr")).lookup_path("OneSpec").should be_nil
      idx.def_map.lookup_path("OneSpec").should be_nil
      idx.view_stats["spec"].should eq 1
    end
  end
end
