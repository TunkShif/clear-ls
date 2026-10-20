require "./support/feature_client"
require "./support/prelude"

CALLS_APP = {
  "src/calls.cr" => <<-CR,
    def run(io : IO, value)
      a = io.gets(10)
      b = io.gets(value)
      c = io.gets("END", chomp: true)
    end
    CR
}

private def hover_at(c, needle, shift = 0) : String
  u = c.open("src/calls.cr")
  h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/calls.cr", needle, shift)})
  h["contents"]["value"].as_s
end

private def definition_lines(c, needle, shift = 0) : Array(Int32)
  u = c.open("src/calls.cr")
  d = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/calls.cr", needle, shift)})
  d.as_a.map(&.["range"]["start"]["line"].as_i)
end

describe "LSP phase 5 overload-aware features" do
  it "hovers the viable overloads of a call" do
    with_client(CALLS_APP, PRELUDE_FILES) do |c|
      h = hover_at(c, "gets(10)")
      h.should contain("def IO#gets(limit : Int, chomp : Bool = false)")
      h.should_not contain("delimiter")
      h = hover_at(c, "gets(value)")
      h.scan("def IO#gets").size.should eq 4
      h = hover_at(c, "gets(\"END\"")
      h.should contain("def IO#gets(delimiter : String, chomp = false)")
      h.scan("def IO#gets").size.should eq 1
    end
  end

  it "goes to the viable overload definitions" do
    with_client(CALLS_APP, PRELUDE_FILES) do |c|
      definition_lines(c, "gets(10)").size.should eq 1
      definition_lines(c, "gets(value)").size.should eq 4
    end
  end
end

private def sig_help(source : String, cursor_marker = "|") : JSON::Any
  off = source.index!(cursor_marker)
  text = source.sub(cursor_marker, "")
  c = FeatureClient.new({"src/calls.cr" => text}, PRELUDE_FILES)
  uri = c.open("src/calls.cr")
  before = text[0, off]
  pos = {line: before.count('\n'), character: off - (before.rindex('\n').try(&.+(1)) || 0)}
  c.request("textDocument/signatureHelp", {textDocument: {uri: uri}, position: pos})
ensure
  c.try(&.cleanup)
end

private def labels_and_active(res : JSON::Any) : Array({String, String?})
  res["signatures"].as_a.map do |s|
    ap = s["activeParameter"].as_i?
    param = ap.try do |i|
      l = s["parameters"][i]["label"].as_a.map(&.as_i)
      s["label"].as_s[l[0]...l[1]]
    end
    {s["label"].as_s, param}
  end
end

describe "LSP phase 5 signature help" do
  it "shows viable overloads first with the active parameter" do
    res = sig_help("def run(io : IO)\n  io.gets(|\nend\n")
    got = labels_and_active(res)
    got.size.should eq 5
    got.map(&.[0]).should contain("gets(limit : Int, chomp : Bool = false) : String?")
    got.find! { |(l, _)| l.starts_with?("gets(limit") }[1].should eq "limit : Int"
    # `'x', ` binds the Char overloads; the active parameter moves.
    got = labels_and_active(sig_help("def run(io : IO)\n  io.gets('x', |)\nend\n"))
    got[0].should eq({"gets(delimiter : Char, chomp : Bool = false) : String?", "chomp : Bool = false"})
    got[1].should eq({"gets(delimiter : Char, limit : Int, chomp = false) : String?", "limit : Int"})
  end

  it "follows named arguments and nested calls" do
    got = labels_and_active(sig_help("def run(io : IO)\n  io.gets(chomp: |)\nend\n"))
    got[0].should eq({"gets(chomp : Bool = true) : String?", "chomp : Bool = true"})
    got = labels_and_active(sig_help("def run(io : IO, s : String)\n  io.gets(s.split(|\nend\n"))
    got.map(&.[0]).should eq ["split(sep : String) : Array(String)"]
    sig_help("def run(io : IO)\n  io.gets(\"(\", |)\nend\n")["signatures"][0]["label"].as_s.should start_with("gets(delimiter : String")
  end

  it "returns nothing outside calls" do
    sig_help("def run(io : IO)\n  x = (1 + |)\nend\n").raw.should be_nil
  end
end

private def complete_in(source : String) : Array(JSON::Any)
  off = source.index!("|")
  text = source.sub("|", "")
  c = FeatureClient.new({"src/calls.cr" => text}, PRELUDE_FILES)
  uri = c.open("src/calls.cr")
  before = text[0, off]
  pos = {line: before.count('\n'), character: off - (before.rindex('\n').try(&.+(1)) || 0)}
  c.request("textDocument/completion", {textDocument: {uri: uri}, position: pos})["items"].as_a
ensure
  c.try(&.cleanup)
end

describe "LSP phase 5 named-argument completion" do
  it "offers parameter names of the viable overloads" do
    items = complete_in("def run(io : IO)\n  io.gets(li|)\nend\n")
    items.first["label"].should eq "limit:"
    items.first["insertText"].should eq "limit: "
    labels = complete_in("def run(io : IO)\n  io.gets(|)\nend\n").map(&.["label"].as_s)
    labels.should contain("chomp:")
    labels.should contain("delimiter:")
    # Already given names are not offered again.
    labels = complete_in("def run(io : IO)\n  io.gets(chomp: true, |)\nend\n").map(&.["label"].as_s)
    labels.should_not contain("chomp:")
    labels.should contain("limit:")
    # Not inside an argument value.
    labels = complete_in("def run(io : IO, x : Int32)\n  io.gets(x.ab|)\nend\n").map(&.["label"].as_s)
    labels.should_not contain("limit:")
  end
end
