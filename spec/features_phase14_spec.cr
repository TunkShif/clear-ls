require "./support/feature_client"

# Phase 14: multi-root workspaces.

private STD = {
  "object.cr" => "class Object\n  def to_s : String\n    \"\"\n  end\nend\n",
  "int.cr"    => "struct Int32\n  def +(other : Int32) : Int32\n    self\n  end\nend\n",
}

# Two projects side by side, each with a `Widget` of its own and its own
# version of the shard `dep` in `lib/`.
private TWO = {
  "app/shard.yml"            => "name: app\ntargets:\n  app:\n    main: src/app.cr\n",
  "app/src/app.cr"           => "require \"dep\"\nclass Widget\n  def app_only; end\nend\nWidget.new.app_only\nDep.v1\n",
  "app/lib/dep/src/dep.cr"   => "module Dep\n  def self.v1; end\nend\n",
  "tool/shard.yml"           => "name: tool\ntargets:\n  tool:\n    main: src/tool.cr\n",
  "tool/src/tool.cr"         => "require \"dep\"\nclass Widget\n  def tool_only; end\nend\nWidget.new.tool_only\nDep.v2\n",
  "tool/lib/dep/src/dep.cr"  => "module Dep\n  def self.v2; end\nend\n",
}

private def with_folders(files, folders, stdlib = STD, compiler = {enabled: false}, &)
  c = FeatureClient.new(files, stdlib, compiler, folders: folders)
  yield c
ensure
  c.try(&.cleanup)
end

private def folders_changed(c : FeatureClient, added = [] of String, removed = [] of String) : Nil
  f = ->(list : Array(String)) { list.map { |p| {uri: VFS.uri_for(File.join(c.root, p)), name: p} } }
  c.notify("workspace/didChangeWorkspaceFolders", {event: {added: f.call(added), removed: f.call(removed)}})
end

private def definition(c : FeatureClient, path : String, needle : String, shift = 0) : Array(String)
  u = c.open(path)
  r = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos(path, needle, shift)})
  r.as_a.map { |l| l["uri"].as_s }
end

describe "multi-root workspaces" do
  it "indexes every workspace folder as its own project" do
    with_folders(TWO, ["app", "tool"]) do |c|
      c.server.indexes.map(&.project.root).should eq [File.join(c.root, "app"), File.join(c.root, "tool")]
      definition(c, "app/src/app.cr", "Widget.new").should eq [c.uri("app/src/app.cr")]
      definition(c, "tool/src/tool.cr", "Widget.new").should eq [c.uri("tool/src/tool.cr")]
    end
  end

  it "resolves shards in each root's own lib/" do
    with_folders(TWO, ["app", "tool"]) do |c|
      definition(c, "app/src/app.cr", "Dep.v1", 4).should eq [c.uri("app/lib/dep/src/dep.cr")]
      definition(c, "tool/src/tool.cr", "Dep.v2", 4).should eq [c.uri("tool/lib/dep/src/dep.cr")]
      # The other root's shard version isn't visible.
      u = c.open("tool/src/tool.cr")
      items = c.request("textDocument/completion", {textDocument: {uri: u}, position: c.pos("tool/src/tool.cr", "Dep.v2", 4)})["items"].as_a
      labels = items.map(&.["label"].as_s)
      labels.should contain "v2"
      labels.should_not contain "v1"
    end
  end

  it "parses library files once for all roots" do
    with_folders(TWO, ["app", "tool"]) do |c|
      first, second = c.server.indexes
      first.parsed.should be >= STD.size
      # The fake stdlib (prelude + files) comes from the first root.
      second.seeded.should eq STD.size + 1
      # Each root's own `lib/dep` differs: parsed by its index.
      second.parsed.should eq 2 # tool.cr, its dep.cr
    end
  end

  it "finds workspace symbols of every root without opening files" do
    with_folders(TWO, ["app", "tool"]) do |c|
      r = c.request("workspace/symbol", {query: "tool_only"})
      r.as_a.map { |s| s["location"]["uri"].as_s }.should eq [c.uri("tool/src/tool.cr")]
    end
  end

  it "answers a library file from the index of the document that led there" do
    with_folders(TWO, ["app", "tool"]) do |c|
      std = File.join(c.root, ".stdlib", "object.cr")
      definition(c, "tool/src/tool.cr", "Widget.new").should eq [c.uri("tool/src/tool.cr")]
      u = VFS.uri_for(std)
      c.notify("textDocument/didOpen", {textDocument: {uri: u, languageId: "crystal", version: 1, text: File.read(std)}})
      r = c.request("workspace/symbol", {query: "Widget"})
      r.as_a.map { |s| s["location"]["uri"].as_s }.sort.should eq [c.uri("app/src/app.cr"), c.uri("tool/src/tool.cr")].sort
      hover = c.request("textDocument/hover", {textDocument: {uri: u}, position: {line: 1, character: 7}})
      hover["contents"]["value"].as_s.should contain "to_s"
      std_id = c.server.vfs.id_for(u)
      c.server.index_for(std_id).project.root.should eq File.join(c.root, "tool")
      definition(c, "app/src/app.cr", "Widget.new")
      c.server.index_for(std_id).project.root.should eq File.join(c.root, "app")
    end
  end

  it "keeps a nested folder apart from its parent" do
    files = {
      "shard.yml"         => "name: outer\ntargets:\n  outer:\n    main: src/outer.cr\n",
      "src/outer.cr"      => "class Thing\nend\nThing.new\n",
      "sub/shard.yml"     => "name: sub\ntargets:\n  sub:\n    main: src/sub.cr\n",
      "sub/src/sub.cr"    => "class Thing\n  def sub; end\nend\nThing.new.sub\n",
    }
    with_folders(files, [".", "sub"]) do |c|
      c.server.indexes.size.should eq 2
      definition(c, "sub/src/sub.cr", "Thing.new").should eq [c.uri("sub/src/sub.cr")]
      definition(c, "src/outer.cr", "Thing.new").should eq [c.uri("src/outer.cr")]
    end
  end

  it "maps folders inside one project to that project" do
    with_folders(TWO, ["app/src", "app"]) do |c|
      c.server.indexes.map(&.project.root).should eq [File.join(c.root, "app")]
    end
  end

  # Runs the installed compiler. Each program needs its project's own
  # `lib/dep` (`Dep.v1` / `Dep.v2`): compiled anywhere else, `require
  # "dep"` fails or finds the wrong version.
  compiler = {enabled: true, debounceMs: 0}
  broken = TWO.merge({
    "app/src/app.cr"  => "require \"dep\"\nDep.v1\n1.app_error\n",
    "tool/src/tool.cr" => "require \"dep\"\nDep.v2\n1.tool_error\n",
  })

  it "checks each folder's programs in its own directory" do
    with_folders(broken, ["app", "tool"], compiler: compiler) do |c|
      c.wait_compiler
      c.diagnostics("app/src/app.cr").not_nil!.map(&.["message"].as_s).should eq ["undefined method 'app_error' for Int32"]
      c.diagnostics("tool/src/tool.cr").not_nil!.map(&.["message"].as_s).should eq ["undefined method 'tool_error' for Int32"]
    end
  end

  it "checks a nested project in its own directory" do
    files = {
      "shard.yml"              => "name: outer\n",
      "sub/shard.yml"          => "name: sub\ntargets:\n  sub:\n    main: src/sub.cr\n",
      "sub/src/sub.cr"         => "require \"dep\"\nDep.v1\n1.sub_error\n",
      "sub/lib/dep/src/dep.cr" => "module Dep\n  def self.v1; end\nend\n",
    }
    with_folders(files, ["."], compiler: compiler) do |c|
      c.open("sub/src/sub.cr")
      c.wait_compiler
      c.diagnostics("sub/src/sub.cr").not_nil!.map(&.["message"].as_s).should eq ["undefined method 'sub_error' for Int32"]
    end
  end

  it "keeps compiler facts in the index of the entry's root" do
    files = TWO.merge({
      "app/src/app.cr"  => "require \"dep\"\nDep.v1\nclass Gen\n  {% for n in %w(made_in_app) %}\n    def {{n.id}}; 1; end\n  {% end %}\nend\nGen.new.made_in_app\n",
      "tool/src/tool.cr" => "require \"dep\"\nDep.v2\nclass Gen\n  {% for n in %w(made_in_tool) %}\n    def {{n.id}}; 1; end\n  {% end %}\nend\nGen.new.made_in_tool\n",
    })
    with_folders(files, ["app", "tool"], compiler: compiler) do |c|
      c.wait_compiler
      app, tool = c.server.indexes
      app.facts.methods.map(&.header).should contain "made_in_app()"
      app.facts.methods.map(&.header).should_not contain "made_in_tool()"
      tool.facts.methods.map(&.header).should contain "made_in_tool()"
      tool.facts.methods.map(&.header).should_not contain "made_in_app()"
    end
  end

  it "advertises workspace folder change notifications" do
    with_folders(TWO, ["app"]) do |c|
      c.init_result.dig("capabilities", "workspace", "workspaceFolders").should eq JSON.parse(%({"supported":true,"changeNotifications":true}))
    end
  end

  it "indexes an added folder and drops a removed one" do
    with_folders(TWO, ["app"]) do |c|
      c.server.indexes.size.should eq 1
      # Before: tool.cr is a loose file of the app's index, whose `lib`
      # is app/lib (Dep has v1 only): Dep.v2 is unknown.
      definition(c, "tool/src/tool.cr", "Dep.v2", 4).should be_empty
      folders_changed(c, added: ["tool"])
      c.server.indexes.map(&.project.root).should eq [File.join(c.root, "app"), File.join(c.root, "tool")]
      definition(c, "tool/src/tool.cr", "Dep.v2", 4).should eq [c.uri("tool/lib/dep/src/dep.cr")]
      folders_changed(c, removed: ["tool"])
      c.server.indexes.map(&.project.root).should eq [File.join(c.root, "app")]
      definition(c, "tool/src/tool.cr", "Dep.v2", 4).should be_empty
      # The kept root still answers.
      definition(c, "app/src/app.cr", "Dep.v1", 4).should eq [c.uri("app/lib/dep/src/dep.cr")]
    end
  end

  it "keeps an edited buffer of a removed folder" do
    with_folders(TWO, ["app", "tool"]) do |c|
      u = c.open("tool/src/tool.cr")
      text = File.read(File.join(c.root, "tool/src/tool.cr")).sub("def tool_only; end", "def tool_only; end\n  def unsaved; end")
      c.notify("textDocument/didChange", {textDocument: {uri: u, version: 2}, contentChanges: [{text: text}]})
      folders_changed(c, removed: ["tool"])
      # Now a loose file of the app's index, with its edited text.
      items = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: 5, character: 11}})["items"].as_a
      items.map(&.["label"].as_s).should contain "unsaved"
    end
  end

  it "keeps the last root when every folder is removed" do
    with_folders(TWO, ["app"]) do |c|
      folders_changed(c, removed: ["app"])
      c.server.indexes.map(&.project.root).should eq [File.join(c.root, "app")]
    end
  end

  it "makes the next root primary when the first is removed" do
    with_folders(TWO, ["app", "tool"]) do |c|
      folders_changed(c, removed: ["app"])
      c.server.primary_index.project.root.should eq File.join(c.root, "tool")
      r = c.request("workspace/symbol", {query: "app_only"})
      r.as_a.should be_empty
    end
  end

  it "checks an added folder and clears a removed folder's diagnostics" do
    with_folders(broken, ["app"], compiler: compiler) do |c|
      c.wait_compiler
      c.diagnostics("tool/src/tool.cr").should be_nil
      folders_changed(c, added: ["tool"])
      c.wait_compiler
      c.diagnostics("tool/src/tool.cr").not_nil!.map(&.["message"].as_s).should eq ["undefined method 'tool_error' for Int32"]
      folders_changed(c, removed: ["tool"])
      c.diagnostics("tool/src/tool.cr").should eq [] of JSON::Any
      # The app's diagnostics stay.
      c.diagnostics("app/src/app.cr").not_nil!.size.should eq 1
    end
  end

  it "applies edits to the index that owns the file" do
    with_folders(TWO, ["app", "tool"]) do |c|
      u = c.open("tool/src/tool.cr")
      text = File.read(File.join(c.root, "tool/src/tool.cr")).sub("def tool_only; end", "def tool_only; end\n  def added; end")
      c.notify("textDocument/didChange", {textDocument: {uri: u, version: 2}, contentChanges: [{text: text}]})
      items = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: 5, character: 11}})["items"].as_a
      items.map(&.["label"].as_s).should contain "added"
      app = c.open("app/src/app.cr")
      items = c.request("textDocument/completion", {textDocument: {uri: app}, position: {line: 4, character: 11}})["items"].as_a
      items.map(&.["label"].as_s).should_not contain "added"
    end
  end
end
