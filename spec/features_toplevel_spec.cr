require "./spec_helper"
require "./support/feature_client"
require "./support/prelude"

private def hover_text(c, path, needle, shift = 0) : String
  u = c.open(path)
  h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos(path, needle, shift)})
  h.raw.nil? ? "nil" : h["contents"]["value"].as_s
end

describe "file-level namespace" do
  it "does not treat top-level code as inside a type declared first" do
    files = {"src/a.cr" => <<-CR}
      module App
        class Item
        end
        X = Item.new
      end
      class Other
      end
      x = Item.new
      y = App::Item.new
      CR
    with_client(files, PRELUDE_FILES) do |c|
      # `Item` is not visible at the top level (the compiler: undefined
      # constant Item); it was typed App::Item because the file starts
      # with `module App`.
      hover_text(c, "src/a.cr", "x = ").should contain("```crystal\nx\n```")
      hover_text(c, "src/a.cr", "y = ").should contain("y : App::Item")
      # Inside the module body the lookup still starts in App.
      d = c.request("textDocument/definition", {textDocument: {uri: c.uri("src/a.cr")}, position: c.pos("src/a.cr", "Item.new\nend", 0)})
      d.as_a.size.should eq 1
    end
  end
end
