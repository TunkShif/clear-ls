require "./support/feature_client"
require "./support/prelude"

# Fix round: no type hint where the type is already written.

describe "inlay hints where the type is written" do
  src = <<-CR
    def q2 : Int32
      1
    end

    def run(xs : Array(Int32)) : Nil
      f = ->(x : Int32, y : String) { x }
      g = ->(x : Int32) : Int32 { x }
      xs.each { |e| e }
      u = uninitialized Int32
      v = q2.as(Int32)
      w = q2.as?(Int32)
      t = q2
      {f, g, u, v, w, t}
      nil
    end
    CR

  it "skips annotated proc params, `uninitialized T` and `.as(T)`" do
    with_client({"src/a.cr" => src}, PRELUDE_FILES) do |c|
      u = c.open("src/a.cr")
      hints = c.request("textDocument/inlayHint", {textDocument: {uri: u}, range: {start: {line: 0, character: 0}, end: {line: 20, character: 0}}})
      lines = src.lines
      got = hints.as_a.map do |h|
        l = h["position"]["line"].as_i
        ch = h["position"]["character"].as_i
        "#{lines[l][0, ch].strip}#{h["label"].as_s}"
      end
      got.should eq [
        "f: Int32, String -> Int32",
        "g: Int32 -> Int32",
        "xs.each { |e: Int32",
        "w: Int32?",
        "t: Int32",
      ]
    end
  end
end
