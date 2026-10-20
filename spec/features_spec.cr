require "./spec_helper"
require "file_utils"

include ClearLS
include ClearLS::LSP

private class FeatureClient
  getter server : Server
  @out = IO::Memory.new
  @next_id = 0
  getter root : String

  def initialize(files : Hash(String, String))
    @root = File.tempname("clear-ls-feat")
    files.each do |path, text|
      full = File.join(@root, path)
      Dir.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
    @server = Server.new(Transport.new(IO::Memory.new, @out))
    @server.project_factory = ->(root : String) { Workspace::Project.new(root, ["lib"], nil, nil, "x86_64-unknown-linux-gnu") }
    @server.index_workers = 1
    request("initialize", {rootUri: VFS.uri_for(@root), capabilities: {general: {positionEncodings: ["utf-16"]}}})
    notify("initialized", {} of String => String)
  end

  def cleanup
    FileUtils.rm_rf(@root)
  end

  def uri(path : String) : String
    VFS.uri_for(File.join(@root, path))
  end

  def open(path : String) : String
    u = uri(path)
    notify("textDocument/didOpen", {textDocument: {uri: u, languageId: "crystal", version: 1, text: File.read(File.join(@root, path))}})
    u
  end

  def request(method : String, params = nil) : JSON::Any
    @next_id += 1
    @server.dispatch({jsonrpc: "2.0", id: @next_id, method: method, params: params}.to_json)
    reply = last
    raise "#{method}: #{reply["error"]}" if reply["error"]?
    reply["result"]
  end

  def notify(method : String, params = nil) : Nil
    @server.dispatch({jsonrpc: "2.0", method: method, params: params}.to_json)
  end

  # Position of the first occurrence of *needle* (plus *shift* chars) in *path*.
  def pos(path : String, needle : String, shift = 0)
    text = File.read(File.join(@root, path))
    off = text.index!(needle) + shift
    before = text[0, off]
    line = before.count('\n')
    col = off - (before.rindex('\n').try(&.+(1)) || 0)
    {line: line, character: col}
  end

  private def last : JSON::Any
    t = Transport.new(IO::Memory.new(@out.to_s), IO::Memory.new)
    result = JSON::Any.new(nil)
    while body = t.read
      result = JSON.parse(body)
    end
    result
  end
end

private def with_client(files, &)
  c = FeatureClient.new(files)
  yield c
ensure
  c.try(&.cleanup)
end

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
      links.as_a.map(&.["target"].as_s).should eq [c.uri("src/models/user.cr"), c.uri("lib/dep/src/dep.cr")]
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
