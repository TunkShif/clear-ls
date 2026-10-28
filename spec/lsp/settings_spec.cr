require "../spec_helper"
require "../support/feature_client"
require "../support/prelude"

include ClearLS::LSP

describe Settings do
  it "has defaults, applies nested objects and reports changes" do
    s = Settings.new
    s.bool("compiler.enabled").should be_true
    s.float("budgets.references").should eq 5.0
    s.string?("compiler.path").should be_nil
    changed = s.apply(JSON.parse(%({"compiler": {"enabled": false, "path": "/x/crystal"}, "budgets": {"references": 2}})))
    changed.sort.should eq ["budgets.references", "compiler.enabled", "compiler.path"]
    s.bool("compiler.enabled").should be_false
    s.float("budgets.references").should eq 2.0
    s.string?("compiler.path").should eq "/x/crystal"
    s.apply(JSON.parse(%({"compiler": {"enabled": false}}))).should be_empty
  end

  it "ignores unknown keys and wrong types" do
    s = Settings.new
    s.apply(JSON.parse(%({"nope": 1, "compiler": {"enabled": "yes", "entries": [1]}, "budgets": "x"}))).should be_empty
    s.bool("compiler.enabled").should be_true
    s.strings?("compiler.entries").should be_nil
  end

  it "keeps docs/settings.md current" do
    path = File.expand_path("../../docs/settings.md", __DIR__)
    File.read(path).should eq(Settings.markdown), "docs/settings.md is stale: run `bin/clear-ls settings-doc > docs/settings.md`"
  end

  it "applies workspace/didChangeConfiguration" do
    c = FeatureClient.new({"src/a.cr" => "x = 1\n"}, references: {includePossible: false})
    begin
      c.notify("workspace/didChangeConfiguration", {settings: {clearLs: {references: {includePossible: true}}}})
      c.server.settings.bool("references.includePossible").should be_true
      # Clients that send the section unwrapped.
      c.notify("workspace/didChangeConfiguration", {settings: {references: {includePossible: false}}})
      c.server.settings.bool("references.includePossible").should be_false
    ensure
      c.cleanup
    end
  end
end

describe "inlay hint settings" do
  files = {"src/a.cr" => "def twice(x : Int32)\n  x * 2\nend\n\ndef go\n  v = twice(1)\n  [\"a\"].each { |s| puts s }\nend\n"}

  it "switches kinds and refreshes" do
    c = FeatureClient.new(files, PRELUDE_FILES, workspace_caps: {inlayHint: {refreshSupport: true}})
    begin
      u = c.open("src/a.cr")
      hints = -> { c.request("textDocument/inlayHint", {textDocument: {uri: u}, range: {start: {line: 0, character: 0}, end: {line: 9, character: 0}}}).as_a.map(&.["label"].as_s) }
      hints.call.sort.should eq [" : Int32", " : Nil", ": Int32", ": String"]
      c.notify("workspace/didChangeConfiguration", {settings: {clearLs: {inlayHints: {returnTypes: false, blockParams: false}}}})
      hints.call.should eq [": Int32"]
      c.server_messages("workspace/inlayHint/refresh").size.should eq 1
      c.notify("workspace/didChangeConfiguration", {settings: {clearLs: {inlayHints: {enabled: false}}}})
      hints.call.should be_empty
    ensure
      c.cleanup
    end
  end
end
