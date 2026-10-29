require "./support/feature_client"

SNIPPET_CAPS = {completion: {completionItem: {snippetSupport: true, insertTextModeSupport: {valueSet: [1, 2]}}}}

# Completion items at the `‸` in *path*'s text (the marker is removed
# before the file is written).
private def items_at(files : Hash(String, String), path : String, caps = SNIPPET_CAPS, settings = nil, real_stdlib = false) : Array(JSON::Any)
  marked = files[path]
  cur = marked.index!('‸')
  line = marked[0, cur].count('\n')
  col = cur - (marked.rindex('\n', cur - 1).try(&.+(1)) || 0)
  plain = files.transform_values(&.sub("‸", ""))
  c = FeatureClient.new(plain, text_document_caps: caps, real_stdlib: real_stdlib)
  begin
    c.notify("workspace/didChangeConfiguration", {settings: {clearLs: settings}}) if settings
    u = c.open(path)
    r = c.request("textDocument/completion", {textDocument: {uri: u}, position: {line: line, character: col}})
    r["items"].as_a
  ensure
    c.cleanup
  end
end

private def do_item(src : String, **opts) : JSON::Any?
  items_at({"src/a.cr" => src}, "src/a.cr", **opts).find { |i| i["label"] == "do" && i["kind"] == 15 }
end

describe "do ... end snippet (Phase 13)" do
  defs = <<-CR
    def each_pair(&)
      yield key, value
    end
    def walk(& : Int32, String ->)
    end
    def plain(x)
    end
    def implicit
      yield elem
    end

    CR

  it "fills block parameters from the called def" do
    i = do_item(defs + "each_pair d‸\n").not_nil!
    i["textEdit"]["newText"].should eq "do |${1:key}, ${2:value}|\n\t$0\nend"
    i["insertTextFormat"].should eq 2
    i["insertTextMode"].should eq 2
    i["detail"].should eq "do |key, value| ... end"
    # Arity from the restriction, names unknown: placeholders.
    do_item(defs + "walk do‸\n").not_nil!["textEdit"]["newText"].should eq "do |${1:x}, ${2:y}|\n\t$0\nend"
    # No block parameter, but the body yields: the compiler adds one.
    do_item(defs + "implicit d‸\n").not_nil!["textEdit"]["newText"].should eq "do |${1:elem}|\n\t$0\nend"
  end

  it "uses the stdlib's block methods" do
    do_item("xs = [1, 2]\nxs.each d‸\n", real_stdlib: true).not_nil!["textEdit"]["newText"].should eq "do |${1:x}|\n\t$0\nend"
    do_item("xs = [1, 2]\nxs.each_slice(2) do‸\n", real_stdlib: true).not_nil!["textEdit"]["newText"].as_s.should start_with "do |${1:"
  end

  it "binds like the parser: `foo arg do` goes to foo" do
    do_item(defs + "each_pair plain(1) d‸\n").not_nil!["textEdit"]["newText"].as_s.should start_with "do |${1:key}"
  end

  it "offers a plain block for unknown calls, nothing for blockless defs" do
    do_item("whatever d‸\n").not_nil!["textEdit"]["newText"].should eq "do\n\t$0\nend"
    do_item(defs + "plain 1 d‸\n").should be_nil
  end

  it "is not offered off a call" do
    do_item("d‸\n").should be_nil
    do_item("x = 1 d‸\n").should be_nil
    do_item(defs + "each_pair { } d‸\n").should be_nil # already has a block
    do_item(defs + "each_pair d‸ foo\n").should be_nil
    do_item(defs + "each_pair # d‸\n").should be_nil  # comment: no item at all
  end

  it "follows the setting and the client's snippet support" do
    do_item(defs + "each_pair d‸\n", settings: {completion: {doSnippet: false}}).should be_nil
    do_item(defs + "each_pair d‸\n", caps: {completion: {completionItem: {snippetSupport: false}}}).should be_nil
    # Without insertTextModeSupport: no insertTextMode.
    i = do_item(defs + "each_pair d‸\n", caps: {completion: {completionItem: {snippetSupport: true}}}).not_nil!
    i["insertTextMode"]?.should be_nil
  end

  it "keeps the keyword item" do
    labels = items_at({"src/a.cr" => defs + "each_pair d‸\n"}, "src/a.cr").select { |i| i["label"] == "do" }.map(&.["kind"].as_i)
    labels.sort.should eq [14, 15]
  end
end
