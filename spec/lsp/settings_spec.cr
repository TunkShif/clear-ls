require "../spec_helper"
require "../support/feature_client"

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
