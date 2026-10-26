require "./spec_helper"
require "./support/feature_client"
require "./support/prelude"

# Runs the installed compiler (~0.5 s per check).
private COMPILER = {enabled: true, debounceMs: 0}

describe "compiler diagnostics" do
  it "publishes errors of shard targets at startup, with codepoint columns" do
    with_client({
      "shard.yml"  => "name: x\ntargets:\n  x:\n    main: src/x.cr\n",
      "src/x.cr"   => "require \"./util\"\nputs twice(2)\n",
      "src/util.cr" => "def twice(n)\n  s = \"😀\"; n.nope\nend\n",
    }, compiler: COMPILER) do |c|
      c.wait_compiler
      diags = c.diagnostics("src/util.cr").not_nil!
      diags.size.should eq 1
      d = diags.first
      d["message"].should eq "undefined method 'nope' for Int32"
      d["severity"].should eq 1
      d["source"].should eq "crystal"
      # `  s = "😀"; n.nope`: compiler column 14 (codepoints, 1-based) is
      # utf-16 character 14 (the emoji is two units).
      d["range"].should eq JSON.parse(%({"start":{"line":1,"character":14},"end":{"line":1,"character":18}}))
      d["relatedInformation"][0]["message"].as_s.should contain "instantiating 'twice(Int32)'"
      d["relatedInformation"][0]["location"]["uri"].should eq c.uri("src/x.cr")
    end
  end

  it "clears diagnostics after a fixing save" do
    with_client({
      "shard.yml" => "name: x\ntargets:\n  x:\n    main: src/x.cr\n",
      "src/x.cr"  => "1.nope\n",
    }, compiler: COMPILER) do |c|
      c.wait_compiler
      c.diagnostics("src/x.cr").not_nil!.size.should eq 1
      File.write(File.join(c.root, "src/x.cr"), "puts 1\n")
      c.notify("textDocument/didSave", {textDocument: {uri: c.uri("src/x.cr")}})
      c.wait_compiler
      c.diagnostics("src/x.cr").should eq [] of JSON::Any
    end
  end

  it "checks a file outside every target on open, warnings included" do
    with_client({
      "scripts/s.cr" => "@[Deprecated(\"no\")]\ndef old; end\nold\n",
    }, compiler: COMPILER) do |c|
      c.wait_compiler
      c.diagnostics("scripts/s.cr").should be_nil
      c.open("scripts/s.cr")
      c.wait_compiler
      d = c.diagnostics("scripts/s.cr").not_nil!.first
      d["severity"].should eq 2
      d["message"].should eq "Deprecated ::old. no"
      d["range"]["start"].should eq JSON.parse(%({"line":2,"character":0}))
    end
  end

  it "reports stdlib errors at the workspace call" do
    with_client({"a.cr" => "[1, 2].sum(\"a\")\n"}, compiler: COMPILER) do |c|
      c.open("a.cr")
      c.wait_compiler
      d = c.diagnostics("a.cr").not_nil!.first
      d["message"].as_s.should start_with "expected argument #1 to 'String#+'"
      d["range"]["start"].should eq JSON.parse(%({"line":0,"character":7}))
      d["relatedInformation"].as_a.last["location"]["uri"].as_s.should end_with "enumerable.cr"
    end
  end

  it "republishes known problems when a checked file is reopened" do
    with_client({
      "shard.yml" => "name: x\ntargets:\n  x:\n    main: src/x.cr\n",
      "src/x.cr"  => "1.nope\n",
    }, compiler: COMPILER) do |c|
      c.wait_compiler
      count = ->{ c.notifications("textDocument/publishDiagnostics").count { |n| n["uri"] == c.uri("src/x.cr") } }
      count.call.should eq 1
      # Neovim's `:e`: the client drops the diagnostics on didClose.
      u = c.open("src/x.cr")
      c.notify("textDocument/didClose", {textDocument: {uri: u}})
      c.open("src/x.cr")
      c.wait_compiler
      count.call.should eq 3
      c.diagnostics("src/x.cr").not_nil!.size.should eq 1
    end
  end

  it "stays quiet when disabled" do
    with_client({"a.cr" => "1.nope\n"}) do |c|
      c.open("a.cr")
      c.server.checker.should be_nil
      c.notifications("textDocument/publishDiagnostics").should be_empty
    end
  end
end

describe "formatting" do
  it "diffs whole lines" do
    Server.line_diff("a\nb\nc\n", "a\nb\nc\n").should be_nil
    r, t = Server.line_diff("a\n b\nc\n", "a\nb\nc\n").not_nil!
    {r.start, r.end, t}.should eq({2, 5, "b\n"})
    r, t = Server.line_diff("a\nb", "a\nb\n").not_nil!
    {r.start, r.end, t}.should eq({2, 3, "b\n"})
    r, t = Server.line_diff("x\n", "").not_nil!
    {r.start, r.end, t}.should eq({0, 2, ""})
  end

  it "formats the buffer (unsaved text) with crystal tool format" do
    with_client({"a.cr" => "def foo\n  1\nend\n"}) do |c|
      u = c.open("a.cr")
      c.notify("textDocument/didChange", {textDocument: {uri: u, version: 2},
        contentChanges: [{text: "def foo\n  1\nend\n\ndef bar( x )\n x+1\nend\n"}]})
      edits = c.request("textDocument/formatting", {textDocument: {uri: u}, options: {tabSize: 2, insertSpaces: true}}).as_a
      edits.size.should eq 1
      edits[0]["range"].should eq JSON.parse(%({"start":{"line":4,"character":0},"end":{"line":6,"character":0}}))
      edits[0]["newText"].should eq "def bar(x)\n  x + 1\n"
    end
  end

  it "returns null on a syntax error" do
    with_client({"a.cr" => "def foo(\n"}) do |c|
      u = c.open("a.cr")
      c.request("textDocument/formatting", {textDocument: {uri: u}, options: {tabSize: 2, insertSpaces: true}}).raw.should be_nil
      c.notifications("window/logMessage").last["message"].as_s.should contain "syntax error"
    end
  end
end

describe "clearLs/expandMacro" do
  files = {
    "shard.yml"     => "name: x\ntargets:\n  x:\n    main: src/x.cr\n",
    "src/x.cr"      => "require \"./model\"\nputs Model.new.size\n",
    "src/model.cr"  => "macro twice(name)\n  def {{name.id}}; 2; end\nend\n\nclass Model\n  x = \"😀\"; getter size : Int32 = 1\n  twice width\nend\n",
  }

  it "expands a macro call in a required file" do
    with_client(files) do |c|
      u = c.open("src/model.cr")
      # On `getter`, after the emoji (utf-16 column 12).
      r = c.request("clearLs/expandMacro", {textDocument: {uri: u}, position: c.pos("src/model.cr", "getter", 2)})
      r["status"].should eq "ok"
      e = r["expansions"][0]
      e["original"].should eq "getter(size : Int32 = 1)"
      e["steps"][0]["source"].as_s.should contain "def size : Int32"
      m = e["steps"][0]["macros"][0]
      m["name"].should eq "getter"
      m["location"]["uri"].as_s.should end_with "object/properties.cr"

      r = c.request("clearLs/expandMacro", {textDocument: {uri: u}, position: c.pos("src/model.cr", "twice width")})
      r["expansions"][0]["steps"][0]["source"].as_s.should contain "def width"
      r["expansions"][0]["steps"][0]["macros"][0]["location"]["uri"].should eq u
    end
  end

  it "fails softly outside macros and refuses unsaved buffers" do
    with_client(files) do |c|
      u = c.open("src/model.cr")
      r = c.request("clearLs/expandMacro", {textDocument: {uri: u}, position: {line: 0, character: 1}})
      r["status"].should eq "failed"
      c.notify("textDocument/didChange", {textDocument: {uri: u, version: 2}, contentChanges: [{text: "# changed\n"}]})
      expect_raises(Exception, /save the file first/) do
        c.request("clearLs/expandMacro", {textDocument: {uri: u}, position: {line: 0, character: 1}})
      end
    end
  end
end

describe "compiler facts" do
  files = {
    "shard.yml"  => "name: x\ntargets:\n  x:\n    main: src/x.cr\n",
    "src/x.cr"   => <<-CR,
      module Plug
        macro included
          def plugged : String; "yes"; end
        end
      end

      class Crate
        include Plug
        {% for n in %w(width height) %}
          def {{n.id}} : Int32; 1; end
        {% end %}

        def initialize
          @label = "box"
          @sizes = [] of Int32
        end

        def label_size
          @label.size
        end
      end

      b = Crate.new
      w = b.width
      p = b.plugged
      puts w, p, b.label_size
      CR
  }

  it "adds generated methods and ivar types after a check" do
    # Fake stdlib for the index (Int32, String); the compiler uses the real one.
    with_client(files, PRELUDE_FILES, compiler: COMPILER) do |c|
      u = c.open("src/x.cr")
      c.wait_compiler
      c.server.index.facts.methods.should_not be_empty
      c.server.index.def_map
      c.server.index.fact_members.should be > 0
      # `w = b.width` (from `{% for %}`) and `p = b.plugged` (from a hook).
      hover = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/x.cr", "w = b")})
      hover["contents"]["value"].as_s.should contain "Int32"
      hover = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/x.cr", "p = b")})
      hover["contents"]["value"].as_s.should contain "String"
      # `@label` has no declaration; the compiler typed it.
      hover = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/x.cr", "@label.size")})
      hover["contents"]["value"].as_s.should contain "@label : String"
      hover["contents"]["value"].as_s.should contain "type from the compiler"
      hover = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/x.cr", "b.width", 2)})
      hover["contents"]["value"].as_s.should contain "generated by a macro"
      # Declared in source: not added again.
      c.server.index.def_map.lookup_member(c.server.index.def_map.lookup_path("Crate").not_nil!, "label_size").size.should eq 1
      # Generated method: definition goes to the generating code.
      defn = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/x.cr", "b.width", 2)})
      defn[0]["range"]["start"].should eq JSON.parse(%({"line":8,"character":2})) # the {% for %}
    end
  end

  it "asks the client to refresh inlay hints and tokens when facts change" do
    caps = {inlayHint: {refreshSupport: true}, semanticTokens: {refreshSupport: true}}
    with_client(files, PRELUDE_FILES, compiler: COMPILER, workspace_caps: caps) do |c|
      c.open("src/x.cr")
      c.wait_compiler
      c.server_messages("workspace/inlayHint/refresh").size.should eq 1
      c.server_messages("workspace/semanticTokens/refresh").size.should eq 1
      c.server_messages("workspace/inlayHint/refresh")[0]["id"]?.should_not be_nil
    end
    # Not advertised: nothing sent.
    with_client(files, PRELUDE_FILES, compiler: COMPILER) do |c|
      c.open("src/x.cr")
      c.wait_compiler
      c.server_messages("workspace/inlayHint/refresh").should be_empty
    end
  end
end

describe "compiler-confirmed hover" do
  files = {
    "a.cr" => "def twice(x)\n  y = x + x\n  y\nend\n\ndef never(z)\n  w = z\nend\n\ntwice(1)\ntwice(\"a\")\n",
  }

  it "adds the compiler's types per instantiation after a background run" do
    with_client(files, compiler: {enabled: true, debounceMs: 0, facts: false}) do |c|
      u = c.open("a.cr")
      c.wait_compiler
      first = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("a.cr", "y\nend")})
      first["contents"]["value"].as_s.should_not contain "compiler:"
      wait_contexts(c)
      again = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("a.cr", "y\nend")})
      again["contents"]["value"].as_s.should contain "compiler: `Int32` · `String`"
      # Never instantiated: the top-level fallback is not shown.
      c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("a.cr", "w = z")})
      wait_contexts(c)
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("a.cr", "w = z")})
      h["contents"]["value"].as_s.should_not contain "compiler:"
      # Unsaved edits: no compiler types.
      c.notify("textDocument/didChange", {textDocument: {uri: u, version: 2}, contentChanges: [{text: File.read(File.join(c.root, "a.cr")) + "\n"}]})
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("a.cr", "y\nend")})
      h["contents"]["value"].as_s.should_not contain "compiler:"
    end
  end
end

def wait_contexts(c : FeatureClient)
  deadline = Time.instant + 30.seconds
  sleep 20.milliseconds
  until c.server.contexts.values.all? { |v| !v.nil? } || !c.server.context_running?
    raise "context still running" if Time.instant > deadline
    sleep 20.milliseconds
  end
end
