require "./support/feature_client"
require "./support/prelude"

TYPED_APP = {
  "src/app.cr" => <<-CR,
    module App
      # A person.
      class User
        getter name : String
        @age : Int32

        def initialize(@name : String, @age : Int32)
        end

        # Display string.
        def label(prefix : String) : String
          prefix + name
        end

        def self.build(name : String) : User
          new(name, 0)
        end
      end

      def self.run(users : Array(User))
        first = users.first
        names = users.map { |u| u.name }
        count = names.size
        maybe = first.name
        x = 
      end
    end
    CR
}

private def labels(res : JSON::Any) : Array(String)
  res["items"].as_a.map(&.["label"].as_s)
end

# Opens a fresh client whose buffer has *insert* typed at *needle*, and
# completes right after it.
private def complete_after(path : String, needle : String, insert : String) : JSON::Any
  c = FeatureClient.new(TYPED_APP, PRELUDE_FILES)
  uri = c.open(path)
  pos = c.pos(path, needle, needle.rstrip('\n').size)
  c.notify("textDocument/didChange", {
    textDocument:   {uri: uri, version: 99},
    contentChanges: [{range: {start: pos, end: pos}, text: insert}],
  })
  lines = insert.split('\n')
  line = pos[:line] + lines.size - 1
  col = lines.size == 1 ? pos[:character] + insert.size : lines.last.size
  c.request("textDocument/completion", {textDocument: {uri: uri}, position: {line: line, character: col}})
ensure
  c.try(&.cleanup)
end

describe "LSP phase 3 features" do
  it "hovers locals with inferred types" do
    with_client(TYPED_APP, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "first = ")})
      h["contents"]["value"].as_s.should start_with("```crystal\nfirst : App::User\n```")
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "names = ")})
      h["contents"]["value"].as_s.should contain("names : Array(String)")
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "u.name")})
      h["contents"]["value"].as_s.should contain("u : App::User")
    end
  end

  it "hovers and navigates method calls through inferred receivers" do
    with_client(TYPED_APP, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "name\n    end")})
      h["contents"]["value"].as_s.should contain("def App::User#name() : String")
      h = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/app.cr", "size")})
      h["contents"]["value"].as_s.should contain("→ `Int32`")
      d = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", "name\n    end")})
      d[0]["uri"].should eq u
      d[0]["range"]["start"]["line"].should eq 3
      # `new` inside `self.build` resolves on the class side.
      d = c.request("textDocument/definition", {textDocument: {uri: u}, position: c.pos("src/app.cr", "first\n")})
      d[0]["uri"].as_s.should end_with("enumerable.cr")
    end
  end

  it "completes members of inferred receivers" do
    with_client(TYPED_APP, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      res = complete_after("src/app.cr", "x = \n", "first.")
      ls = labels(res)
      ls.should contain("name")
      ls.should contain("label")
      ls.should contain("to_s") # from Object
      ls.should_not contain("initialize")
      item = res["items"].as_a.find! { |i| i["label"] == "label" }
      item["detail"].should eq "label(prefix : String) : String"
      item["documentation"]["value"].should eq "Display string."
      item["kind"].should eq 2
    end
  end

  it "completes with a prefix, on chains, and on classes" do
    with_client(TYPED_APP, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      labels(complete_after("src/app.cr", "x = \n", "count.ab")).should eq ["abs"]
      ls = labels(complete_after("src/app.cr", "x = \n", "names.first."))
      ls.should contain("upcase")
      ls = labels(complete_after("src/app.cr", "x = \n", "User."))
      ls.should contain("build")
      ls.should contain("new")
      ls.should_not contain("label")
    end
  end

  it "completes locals, self methods, constants, and paths" do
    with_client(TYPED_APP, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      res = c.request("textDocument/completion", {textDocument: {uri: u}, position: c.pos("src/app.cr", "x = ", 4)})
      items = res["items"].as_a
      first = items.find! { |i| i["label"] == "first" }
      first["detail"].should eq "App::User"
      first["kind"].should eq 6
      labels(res).should contain("users")
      labels(res).should_not contain("x = ")
      ls = labels(complete_after("src/app.cr", "x = \n", "App::"))
      ls.should eq ["User"]
      ls = labels(complete_after("src/app.cr", "x = \n", "Us"))
      ls.should contain("User")
    end
  end

  it "completes instance variables" do
    with_client(TYPED_APP, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      res = complete_after("src/app.cr", "prefix + name\n", "\n      @")
      ls = labels(res)
      ls.should contain("@age")
      ls.should contain("@name")
    end
  end

  it "returns inlay type hints for non-obvious locals" do
    with_client(TYPED_APP, PRELUDE_FILES) do |c|
      u = c.open("src/app.cr")
      hints = c.request("textDocument/inlayHint", {textDocument: {uri: u}, range: {start: {line: 0, character: 0}, end: {line: 40, character: 0}}})
      got = hints.as_a.map { |h| {h["position"]["line"].as_i, h["label"].as_s} }
      got.should contain({20, ": App::User"})
      got.should contain({21, ": Array(String)"})
      got.should contain({21, ": App::User"}) # block arg `u`
      got.should contain({22, ": Int32"})
    end
  end
end
