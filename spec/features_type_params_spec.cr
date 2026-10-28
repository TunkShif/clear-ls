require "./spec_helper"
require "./support/feature_client"
require "./support/prelude"

# Hover, definition, highlight and tokens on type parameters and
# `forall` variables (after Phase 12).

private SRC = <<-CR
  class Key; end

  class Box(T)
    @value : T

    def initialize(@value : T)
    end

    def get : T
      @value
    end

    def map(& : T -> U) : Box(U) forall U
      Box(U).new(yield @value)
    end

    def self.empty_of : T.class
      T
    end

    def shadow(x : T) : T forall T
      x
    end

    class Inner
      def t : T
      end
    end
  end

  class Box
    def again : T
      @value
    end
  end

  def first_of(xs : Array(E)) : E forall E
    xs.first
  end

  struct Pair(K, *V)
    def initialize(@k : K, *@v : *V)
    end
  end

  class Store(Key)
    def get(k : Key) : Key
      k
    end
  end

  b = Box(Int32).new(1)
  k = Key.new
  CR

private def at(c, needle, shift = 0, nth = 0)
  text = File.read(File.join(c.root, "src/a.cr"))
  off = -1
  (nth + 1).times { off = text.index!(needle, off + 1) }
  off += shift
  before = text[0, off]
  {line: before.count('\n'), character: off - (before.rindex('\n').try(&.+(1)) || 0)}
end

# "line:col" (1-based line) of the *nth* occurrence of *needle* + *shift*.
private def lc(c, needle, shift = 0, nth = 0) : String
  p = at(c, needle, shift, nth)
  "#{p[:line] + 1}:#{p[:character]}"
end

private def def_of(c, u, pos) : Array(String)
  c.request("textDocument/definition", {textDocument: {uri: u}, position: pos}).as_a.map do |l|
    "#{l["range"]["start"]["line"].as_i + 1}:#{l["range"]["start"]["character"].as_i}"
  end
end

private def hover_of(c, u, pos) : String
  h = c.request("textDocument/hover", {textDocument: {uri: u}, position: pos})
  h.raw.nil? ? "" : h["contents"]["value"].as_s
end

describe "type parameters" do
  it "jumps to the declaring token and names the role" do
    with_client({"src/a.cr" => SRC}, PRELUDE_FILES) do |c|
      u = c.open("src/a.cr")
      t_decl = [lc(c, "class Box(T)", 10)]
      {
        {"class Box(T)", 10}  => t_decl,
        {"@value : T", 9}     => t_decl,
        {"@value : T)", 9}    => t_decl,
        {"get : T", 6}        => t_decl,
        {"& : T ->", 4}       => t_decl,
        {"T.class", 0}        => t_decl,
        {"T\n  end\n\n  def shadow", 0} => t_decl,
        {"Array(E)", 6}       => [lc(c, "forall E", 7)],
        {") : E forall", 4}   => [lc(c, "forall E", 7)],
        {"Pair(K, *V)", 9}    => [lc(c, "Pair(K, *V)", 9)],
        {"*@v : *V", 7}       => [lc(c, "Pair(K, *V)", 9)],
        {"(@k : K", 6}        => [lc(c, "Pair(K, *V)", 5)],
        {"again : T", 8}      => t_decl, # reopening without params
      }.each do |(needle, shift), expected|
        def_of(c, u, at(c, needle, shift)).should eq(expected), "definition at #{needle.inspect}"
      end
      # `forall U` and `U` in `T -> U`, `Box(U)`, `Box(U).new`.
      u_decl = [lc(c, "forall U", 7)]
      def_of(c, u, at(c, "T -> U", 5)).should eq u_decl
      def_of(c, u, at(c, ": Box(U)", 6)).should eq u_decl
      def_of(c, u, at(c, "Box(U).new", 4)).should eq u_decl
      hover_of(c, u, at(c, "@value : T", 9)).should contain "type parameter of `Box(T)`"
      hover_of(c, u, at(c, "Pair(K, *V)", 9)).should contain "type parameter of `Pair(K, *V)`"
      hover_of(c, u, at(c, "T -> U", 5)).should contain "free variable of `map` (`forall U`)"
      hover_of(c, u, at(c, "again : T", 8)).should contain "type parameter of `Box(T)`"
    end
  end

  it "follows the compiler's scoping" do
    with_client({"src/a.cr" => SRC}, PRELUDE_FILES) do |c|
      u = c.open("src/a.cr")
      # `forall T` shadows the type param.
      def_of(c, u, at(c, "shadow(x : T)", 11)).should eq [lc(c, "forall T", 7)]
      # A nested type doesn't see the outer param.
      hover_of(c, u, at(c, "def t : T", 8)).should_not contain "type parameter"
      # A param shadows a constant of the same name.
      def_of(c, u, at(c, "get(k : Key)", 8)).should eq [lc(c, "Store(Key)", 6)]
      hover_of(c, u, at(c, "get(k : Key)", 8)).should contain "type parameter of `Store(Key)`"
      # Outside, `Key` is still the class.
      def_of(c, u, at(c, "Key.new", 0)).should eq [lc(c, "class Key", 6)]
      # The class name in a header is not a param.
      def_of(c, u, at(c, "class Box(T)", 6)).size.should eq 2
    end
  end

  it "highlights uses in scope and marks them as type parameters" do
    with_client({"src/a.cr" => SRC}, PRELUDE_FILES) do |c|
      u = c.open("src/a.cr")
      hl = c.request("textDocument/documentHighlight", {textDocument: {uri: u}, position: at(c, "get : T", 6)}).as_a
      got = hl.map { |h| "#{h["range"]["start"]["line"].as_i + 1}:#{h["range"]["start"]["character"].as_i}" }
      got.should contain lc(c, "class Box(T)", 10)
      got.should contain lc(c, "get : T", 6)
      got.should contain lc(c, "& : T", 4)
      got.should contain lc(c, "T.class")
      got.should_not contain lc(c, "shadow(x : T)", 11) # `forall T`: another T
      got.should_not contain lc(c, "def t : T", 8)      # Inner doesn't see it
      tok = c.request("textDocument/semanticTokens/full", {textDocument: {uri: u}})["data"].as_a.map(&.as_i)
      types = IDE::TokenType.names
      text = File.read(File.join(c.root, "src/a.cr")).lines
      line = col = 0
      found = [] of String
      tok.each_slice(5) do |(dl, dc, len, ty, _)|
        line += dl
        col = dl == 0 ? col + dc : dc
        found << "#{line + 1}:#{text[line][col, len]}:#{types[ty]}" if text[line][col, len]? .in?("T", "U", "Key")
      end
      ln = ->(needle : String) { at(c, needle)[:line] + 1 }
      found.should contain "#{ln.call("@value : T")}:T:TypeParameter"
      found.should contain "#{ln.call("forall U")}:U:TypeParameter"
      found.should contain "#{ln.call("def get(k : Key)")}:Key:TypeParameter"
      found.should contain "#{ln.call("class Key")}:Key:Class"
    end
  end
end

describe "type parameters and references" do
  it "doesn't count a shadowing param as a use of the class" do
    with_client({"src/a.cr" => "class Key; end\n\nclass Store(Key)\n  def get(k : Key) : Key\n    k\n  end\nend\n\nk = Key.new\n"}, PRELUDE_FILES) do |c|
      u = c.open("src/a.cr")
      refs = c.request("textDocument/references", {textDocument: {uri: u}, position: {line: 0, character: 6}, context: {includeDeclaration: true}}).as_a
      refs.map { |r| r["range"]["start"]["line"].as_i + 1 }.sort.should eq [1, 9]
    end
  end
end
