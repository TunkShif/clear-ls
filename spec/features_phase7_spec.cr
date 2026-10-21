require "./spec_helper"
require "./support/feature_client"

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

  it "stays quiet when disabled" do
    with_client({"a.cr" => "1.nope\n"}) do |c|
      c.open("a.cr")
      c.server.checker.should be_nil
      c.notifications("textDocument/publishDiagnostics").should be_empty
    end
  end
end
