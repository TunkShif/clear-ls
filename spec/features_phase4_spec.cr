require "./support/feature_client"
require "./support/prelude"

FLOW_APP = {
  "src/flow.cr" => <<-CR,
    def run(io : IO, c : Bool)
      x = 1
      x = "s"
      x.size
      line = io.gets
      if line
        line.size
      end
      line.size
      y = 1
      y = "t" if c
      case y
      when Int32
        y.abs
      when String
        y.upcase
      end
      z = 
    end
    CR
}

private def hover_text(c, path, needle, shift = 0) : String
  u = c.open(path)
  h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos(path, needle, shift)})
  h["contents"]["value"].as_s
end

describe "LSP phase 4 flow-sensitive features" do
  it "hovers the type at the reference's program point" do
    with_client(FLOW_APP, PRELUDE_FILES) do |c|
      hover_text(c, "src/flow.cr", "x.size").should start_with("```crystal\nx : String\n```")
      hover_text(c, "src/flow.cr", "x = 1").should contain("x : Int32")
      hover_text(c, "src/flow.cr", "line.size\n  end").should contain("line : String\n")
      hover_text(c, "src/flow.cr", "line.size\n  y").should contain("line : String?")
      hover_text(c, "src/flow.cr", "y.abs").should contain("y : Int32\n")
      hover_text(c, "src/flow.cr", "y.upcase").should contain("y : String\n")
    end
  end

  it "completes with types at the cursor" do
    with_client(FLOW_APP, PRELUDE_FILES) do |c|
      u = c.open("src/flow.cr")
      res = c.request("textDocument/completion", {textDocument: {uri: u}, position: c.pos("src/flow.cr", "z = ", 4)})
      items = res["items"].as_a
      items.find! { |i| i["label"] == "x" }["detail"].should eq "String"
      items.find! { |i| i["label"] == "y" }["detail"].should eq "Int32 | String"
    end
  end

  it "completes members of narrowed receivers" do
    with_client(FLOW_APP, PRELUDE_FILES) do |c|
      u = c.open("src/flow.cr")
      res = c.request("textDocument/completion", {textDocument: {uri: u}, position: c.pos("src/flow.cr", "size\n  end", 0)})
      ls = res["items"].as_a.map(&.["label"].as_s)
      ls.should contain("upcase")
    end
  end
end
