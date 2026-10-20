require "./support/feature_client"

LOCALS_APP = {
  "src/app.cr" => <<-CR,
    module App
      class Greeter
        def initialize(@name : String)
        end

        def greet(times = 1)
          message = "hi \#{@name}"
          times.times do |i|
            message += i.to_s
          end
          message
        end
      end
    end
    CR
}

private def decode(data : Array(JSON::Any)) : Array({Int32, Int32, Int32, Int32, Int32})
  line = col = 0
  data.map(&.as_i).each_slice(5).map do |(dl, dc, len, t, m)|
    line += dl
    col = dl == 0 ? col + dc : dc
    {line, col, len, t, m}
  end.to_a
end

describe "LSP phase 2 features" do
  it "goes to local definitions and hovers locals" do
    with_client(LOCALS_APP) do |c|
      u = c.open("src/app.cr")
      d = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", "message\n    end", 0)})
      d[0]["range"]["start"].should eq JSON.parse(%({"line":6,"character":6}))
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "times.times")})
      h["contents"]["value"].as_s.should eq "```crystal\ntimes\n```\n\nparameter"
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "i.to_s")})
      h["contents"]["value"].as_s.should contain("block argument")
    end
  end

  it "highlights reads and writes, and lists references" do
    with_client(LOCALS_APP) do |c|
      u = c.open("src/app.cr")
      hl = c.request("textDocument/documentHighlight", {textDocument: {uri: u}, position: c.pos("src/app.cr", "message =")})
      hl.as_a.map { |h| {h["range"]["start"]["line"].as_i, h["kind"].as_i} }.should eq [{6, 3}, {8, 2}, {8, 3}, {10, 2}]
      refs = c.request("textDocument/references", {textDocument: {uri: u}, position: c.pos("src/app.cr", "message ="), context: {includeDeclaration: false}})
      refs.as_a.map(&.["range"]["start"]["line"].as_i).should eq [8, 8, 10]
    end
  end

  it "renames locals and refuses non-locals" do
    with_client(LOCALS_APP) do |c|
      u = c.open("src/app.cr")
      prep = c.request("textDocument/prepareRename", {textDocument: {uri: u}, position: c.pos("src/app.cr", "message =")})
      prep["placeholder"].should eq "message"
      edit = c.request("textDocument/rename", {textDocument: {uri: u}, position: c.pos("src/app.cr", "message ="), newName: "text"})
      edit["changes"][u].as_a.size.should eq 4
      expect_raises(Exception, /only local variables/) do
        c.request("textDocument/prepareRename", {textDocument: {uri: u}, position: c.pos("src/app.cr", "greet")})
      end
      expect_raises(Exception, /not a valid local/) do
        c.request("textDocument/rename", {textDocument: {uri: u}, position: c.pos("src/app.cr", "message ="), newName: "Text"})
      end
    end
  end

  it "returns semantic tokens for params, locals, ivars, types, and methods" do
    with_client(LOCALS_APP) do |c|
      u = c.open("src/app.cr")
      types = IDE::TokenType.names.map(&.camelcase(lower: true))
      toks = decode(c.request("textDocument/semanticTokens/full", {textDocument: {uri: u}})["data"].as_a)
      text = File.read(File.join(c.root, "src/app.cr")).lines
      named = toks.map { |(l, col, len, t, m)| {text[l][col, len], types[t], m & 1 == 1} }
      named.should contain({"App", "namespace", true})
      named.should contain({"Greeter", "class", true})
      named.should contain({"greet", "method", true})
      named.should contain({"@name", "property", false})
      named.should contain({"times", "parameter", true})
      named.should contain({"message", "variable", true})
      named.should contain({"i", "parameter", false})
      named.should contain({"String", "type", false})
      # Positions are increasing.
      toks.map { |t| {t[0], t[1]} }.should eq toks.map { |t| {t[0], t[1]} }.sort
    end
  end
end
