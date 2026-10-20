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
