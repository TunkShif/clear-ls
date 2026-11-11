require "./support/feature_client"
require "./support/prelude"

# A file whose first item is a def: the file body and that def's body
# start at the same byte, and inference results keyed by body start used
# to cross (wrong types, `Index out of bounds` on hover).
LEADING_DEF = <<-CR
  def add(a, b)
    a + b
  end

  foo = add 1, 2
  bar = add "foo", "bar"
  CR

private def lead_hover(c, path, needle, shift = 0) : String?
  u = c.uri(path)
  h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos(path, needle, shift)})
  h.raw.nil? ? nil : h["contents"]["value"].as_s
end

private def check_leading_def(prefix : String, def_first : Bool)
  # A loose file (no shard.yml) and the same text as a project's target.
  [{"loose/foo.cr", {"loose/foo.cr" => prefix + LEADING_DEF}},
   {"src/app.cr", {"shard.yml" => "name: app\nversion: 0.1.0\ntargets:\n  app:\n    main: src/app.cr\n",
                   "src/app.cr" => prefix + LEADING_DEF}}].each do |path, files|
    c = FeatureClient.new(files, PRELUDE_FILES)
    begin
      u = c.open(path)
      lead_hover(c, path, "a + b").not_nil!.should contain("a") if def_first
      lead_hover(c, path, "foo =").not_nil!.should contain("foo : Int32")
      lead_hover(c, path, "bar =").not_nil!.should contain("bar : String")
      lead_hover(c, path, "add 1").not_nil!.should contain("→ `Int32`")
      lead_hover(c, path, "add \"foo\"").not_nil!.should contain("→ `String`")
      lead_hover(c, path, "a + b").not_nil!.should contain("a") unless def_first
      hints = c.request("textDocument/inlayHint", {textDocument: {uri: u}, range: {start: {line: 0, character: 0}, end: {line: 20, character: 0}}})
      got = hints.as_a.map(&.["label"].as_s)
      got.should contain(": Int32")
      got.should contain(": String")
      refs = c.request("textDocument/references", {textDocument: {uri: u}, position: c.pos(path, "add 1"), context: {includeDeclaration: true}})
      refs.as_a.size.should eq 3
      # Semantic tokens include the file body's locals (`foo` at col 0).
      data = c.request("textDocument/semanticTokens/full", {textDocument: {uri: u}})["data"].as_a.map(&.as_i)
      line = col = 0
      starts = [] of {Int32, Int32}
      data.each_slice(5) do |(dl, dc, _, _, _)|
        col = dl == 0 ? col + dc : dc
        line += dl
        starts << {line, col}
      end
      starts.should contain({c.pos(path, "foo =")[:line], 0})
    ensure
      c.cleanup
    end
  end
end

describe "file starting with a def" do
  it "keeps the file body's and the def's inference apart (def hovered first)" do
    check_leading_def("", def_first: true)
  end

  it "keeps them apart when the file body is inferred first" do
    check_leading_def("", def_first: false)
  end

  it "keeps them apart after leading blank lines" do
    check_leading_def("\n\n", def_first: true)
  end
end
