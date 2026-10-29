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

# The case snippet's text, with tab stops filled by integers so it
# compiles: `in .red?\n    $1` → `in .red?\n    1`.
private def case_item(src : String, **opts) : JSON::Any?
  items_at({"src/a.cr" => src}, "src/a.cr", **opts).find { |i| i["kind"] == 15 && i["label"].as_s.includes?("missing") }
end

private def fill(snippet : String) : String
  snippet.gsub(/\$(\d+)/) { "#{$1}" }
end

# Compiles *src* with the `‸` line replaced by the item's text.
private def compiles?(src : String, snippet : String) : {Bool, String}
  path = File.tempname("clear-ls-case", ".cr")
  File.write(path, src.sub(/^[ \t]*[a-z]*‸$/m) { |m| m.rchop("‸").sub(/[a-z]*\z/, "") + fill(snippet) })
  buf = IO::Memory.new
  ok = Process.run(ENV["CRYSTAL"]? || "crystal", ["build", "--no-codegen", path], output: buf, error: buf).success?
  {ok, buf.to_s}
ensure
  path.try { |p| File.delete?(p) }
end

describe "exhaustive case snippet (Phase 13)" do
  types = <<-CR
    enum Color
      Red
      Green
      Blue
    end
    @[Flags]
    enum Perm
      Read
      Write
    end
    abstract class Shape; end
    class Circle < Shape; end
    abstract class Poly < Shape; end
    class Square < Poly; end
    class Cube < Square; end

    CR
  fixtures = {
    "enum"          => {"def f(x : Color)\n  case x\n  i‸\n  end\nend\np f(Color::Red)\n", "in .red?\n    $1\n  in .green?\n    $2\n  in .blue?\n    $0"},
    "nilable enum"  => {"def f(x : Color?)\n  case x\n  i‸\n  end\nend\np f(nil)\n", "in Color::Red\n    $1\n  in Color::Green\n    $2\n  in Color::Blue\n    $3\n  in nil\n    $0"},
    "union"         => {"def f(x : Int32 | String | Nil)\n  case x\n  in‸\n  end\nend\np f(1)\n", nil},
    "bool"          => {"def f(x : Bool)\n  case x\n  i‸\n  end\nend\np f(true)\n", "in true\n    $1\n  in false\n    $0"},
    "abstract"      => {"def f(x : Shape)\n  case x\n  i‸\n  end\nend\np f(Cube.new)\np f(Circle.new)\n", "in Circle\n    $1\n  in Square\n    $0"},
  }

  fixtures.each do |name, (src, expected)|
    it "covers a #{name} and compiles" do
      i = case_item(types + src, real_stdlib: true).not_nil!
      text = i["textEdit"]["newText"].as_s
      text.should eq expected if expected
      ok, log = compiles?(types + src, text)
      ok.should be_true, "#{name}: #{text.inspect}\n#{log}"
    end
  end

  it "lists only missing branches and keeps the typed keyword" do
    i = case_item(types + "def f(x : Color)\n  case x\n  in .red?\n    1\n  i‸\n  end\nend\n", real_stdlib: true).not_nil!
    i["label"].should eq "in … (2 missing)"
    i["textEdit"]["newText"].should eq "in .green?\n    $1\n  in .blue?\n    $0"
    i["detail"].should eq ".green?, .blue?"
    w = case_item(types + "def f(x : Bool)\n  case x\n  wh‸\n  end\nend\n", real_stdlib: true).not_nil!
    w["textEdit"]["newText"].should eq "when true\n    $1\n  when false\n    $0"
  end

  it "is not offered when it can't be exhaustive or is off" do
    case_item(types + "def f(x : Perm)\n  case x\n  i‸\n  end\nend\n", real_stdlib: true).should be_nil
    case_item(types + "def f(x)\n  case x\n  i‸\n  end\nend\n", real_stdlib: true).should be_nil
    case_item(types + "def f(x : Color)\n  case x\n  when .red?\n  i‸\n  end\nend\n", real_stdlib: true).should be_nil
    case_item(types + "def f(x : Color)\n  case x\n  i‸\n  end\nend\n", real_stdlib: true, settings: {completion: {caseSnippets: false}}).should be_nil
    case_item(types + "def f(x : Color)\n  y = x i‸\nend\n", real_stdlib: true).should be_nil
  end
end

describe "definition and control-flow snippets (Phase 13)" do
  on = {completion: {definitionSnippets: true, controlFlowSnippets: true}}

  snippets = ->(src : String, settings : NamedTuple(completion: NamedTuple(definitionSnippets: Bool, controlFlowSnippets: Bool))?) do
    items_at({"src/a.cr" => src}, "src/a.cr", settings: settings).select { |i| i["kind"] == 15 }.map(&.["label"].as_s).sort
  end

  it "is off by default; the keyword stays" do
    snippets.call("cla‸\n", nil).should be_empty
    items_at({"src/a.cr" => "cla‸\n"}, "src/a.cr").any? { |i| i["label"] == "class" && i["kind"] == 14 }.should be_true
  end

  it "writes skeletons where the compiler accepts them" do
    i = items_at({"src/a.cr" => "cla‸\n"}, "src/a.cr", settings: on).find { |x| x["kind"] == 15 && x["label"] == "class" }.not_nil!
    i["textEdit"]["newText"].should eq "class ${1:Name}\n\t$0\nend"
    i["insertTextMode"].should eq 2
    i["detail"].should eq "class Name … end"
    snippets.call("class A\n  de‸\nend\n", on).should eq ["def"]
    snippets.call("enum E\n  A\n  m‸\nend\n", on).should eq ["macro"] # no `module` in an enum
    # Inside a def: control flow only.
    snippets.call("def f\n  c‸\nend\n", on).should eq ["case"]
    snippets.call("def f\n  i‸\nend\n", on).should eq ["if"]
    # Inside `if` outside a def: no definitions ("can't declare ... dynamically").
    snippets.call("if x\n  cla‸\nend\n", on).should be_empty
    snippets.call("if x\n  wh‸\nend\n", on).should eq ["while"]
  end

  it "is never offered off a statement start" do
    snippets.call("x if i‸\n", on).should be_empty
    snippets.call("x = i‸\n", on).should be_empty
    snippets.call("foo(i‸)\n", on).should be_empty
    snippets.call("return i‸\n", on).should be_empty
  end

  it "skips structural snippets in an enum body, also for control flow" do
    snippets.call("enum E\n  A\n  i‸\nend\n", on).should be_empty
  end
end

describe "require completion (Phase 13)" do
  shard_yml = "name: app\nversion: 0.1.0\ndependencies:\n  web:\n    github: x/web\n  json:\n    github: x/json\ndevelopment_dependencies:\n  timecop:\n    github: x/timecop\n  missing:\n    github: x/missing\n"
  files = {
    "shard.yml"                   => shard_yml,
    "lib/web/shard.yml"           => "name: web\nversion: 1.2.3\ndescription: |\n  A web framework.\n",
    "lib/web/src/web.cr"          => "# Web things.\n#\n# More text.\nmodule Web; end\nclass Web::App; end\nprivate class Hidden; end\ndef web_helper; end\n",
    "lib/web/src/web/cli.cr"      => "module Web::CLI; end\n",
    "lib/web/src/web_cli.cr"      => "",
    "lib/json/src/json.cr"        => "module MyJSON; end\n", # shadows the stdlib's json
    "lib/timecop/src/timecop.cr"  => "",
    "lib/dbx/src/dbx.cr"          => "", # transitive
    "src/app.cr"                  => "require \"web\"\nrequire \"uri\"\nmodule App; end\n",
    "src/models/user.cr"          => "",
    "src/models/post.cr"          => "",
    "src/empty_dir/.keep"         => "",
    "src/nested/nested.cr"        => "",
    "src/nested/part.cr"          => "",
  }

  labels = ->(line : String, extra : Hash(String, String)) do
    fs = files.merge(extra).merge({"src/main.cr" => line})
    items_at(fs, "src/main.cr", real_stdlib: true).map(&.["label"].as_s)
  end
  item = ->(line : String, label : String) do
    fs = files.merge({"src/main.cr" => line})
    items_at(fs, "src/main.cr", real_stdlib: true).find(&.["label"].==(label))
  end

  it "lists local files, directories and dir/dir.cr" do
    l = labels.call("require \"./‸\n", {} of String => String)
    l.should contain "app"
    l.should contain "models/"
    l.should contain "nested/"
    l.should contain "nested" # nested/nested.cr
    l.should_not contain "main" # the file itself
    l.should_not contain "empty_dir/"
    l.should_not contain "models" # a bare directory doesn't resolve
    labels.call("require \"./models/‸\n", {} of String => String).sort.should eq ["post", "user"]
    labels.call("require \"../src/models/u‸\n", {} of String => String).should eq ["user"]
  end

  it "replaces only the last segment" do
    i = item.call("require \"./models/us‸\"\n", "user").not_nil!
    i["textEdit"]["newText"].should eq "user"
    i["textEdit"]["range"]["start"]["character"].should eq 18
    i["textEdit"]["range"]["end"]["character"].should eq 20
    i["kind"].should eq 17
  end

  it "offers direct shards by name only" do
    l = labels.call("require \"‸\n", {} of String => String)
    l.should contain "web"
    l.should contain "timecop" # development dependency
    l.should_not contain "dbx" # transitive
    l.should_not contain "missing" # not installed
    l.should_not contain "web_cli"
    l.count("json").should eq 1 # the shard shadows the stdlib name
    item.call("require \"we‸\n", "web").not_nil!["detail"].as_s.should end_with "shard 1.2.3"
    # No subpaths for shards.
    labels.call("require \"web/‸\n", {} of String => String).should be_empty
  end

  it "lists the stdlib one level at a time, internals hidden, no globs" do
    l = labels.call("require \"‸\n", {} of String => String)
    %w(http yaml uri option_parser spec).each { |n| l.should contain n }
    %w(array string prelude crystal compiler llvm lib_c lib_z docs_main).each { |n| l.should_not contain n }
    l.any?(&.includes?('*')).should be_false
    l.should_not contain "http/" # `http.cr` and `http/`: one item
    h = labels.call("require \"http/‸\n", {} of String => String)
    h.should contain "client"
    h.should contain "server"
    h.any?(&.includes?('*')).should be_false
    labels.call("require \"openssl/‸\n", {} of String => String).any?(&.starts_with?("lib_")).should be_false
  end

  it "describes indexed files and shards" do
    w = item.call("require \"we‸\n", "web").not_nil!
    w["detail"].should eq "Web, Web::App, web_helper — shard 1.2.3"
    w["documentation"]["value"].should eq "A web framework." # shard.yml first
    a = item.call("require \"./ap‸\n", "app").not_nil!
    a["detail"].should eq "App — file"
    item.call("require \"ur‸\n", "uri").not_nil!["detail"].as_s.should start_with "URI"
    item.call("require \"ht‸\n", "http").not_nil!["detail"].should eq "stdlib (also http/)" # not required anywhere
    # Not indexed (nothing requires it): the plain detail, no parse.
    item.call("require \"./models/u‸\n", "user").not_nil!["detail"].should eq "file"
  end

  it "skips requires already written and answers nothing outside require strings" do
    labels.call("require \"./app\"\nrequire \"./‸\n", {} of String => String).should_not contain "app"
    labels.call("x = \"./‸\n", {} of String => String).should be_empty
    labels.call("# see a/‸\n", {} of String => String).should be_empty
  end

  it "only suggests strings that resolve to the file they name (stdlib round trip)" do
    c = FeatureClient.new({"src/main.cr" => ""}, real_stdlib: true)
    begin
      project = c.server.index.project
      std = project.stdlib_dir.not_nil!
      checked = 0
      dirs = [""] + Dir.glob(File.join(std, "**/")).map { |d| d.lchop(std).lchop('/') }.reject(&.empty?)
      dirs.each do |d|
        rc = IDE::RequireCompletion.new(project, File.join(c.root, "src/main.cr"))
        rc.items(IDE::RequireCompletion::Context.new(d, 0, 0)).each do |i|
          next if i.directory
          project.resolver.resolve("#{d}#{i.label}", nil).first?.should eq(i.target), "#{d}#{i.label}"
          checked += 1
        end
      end
      # Every stdlib file except prelude-loaded ones and internals (386
      # with Crystal 1.22).
      checked.should be > 300
    ensure
      c.cleanup
    end
  end
end

describe "written requires keep resolving (Phase 13)" do
  it "goes to shard subpaths, transitive shards and globs" do
    files = {
      "shard.yml"              => "name: app\nversion: 0.1.0\ndependencies:\n  web:\n    github: x/web\n",
      "lib/web/src/web.cr"     => "",
      "lib/web/src/web/cli.cr" => "",
      "lib/dbx/src/dbx.cr"     => "",
      "src/a/x.cr"             => "",
      "src/main.cr"            => "require \"web/cli\"\nrequire \"dbx\"\nrequire \"./a/*\"\n",
    }
    c = FeatureClient.new(files, real_stdlib: true)
    begin
      u = c.open("src/main.cr")
      {0 => "lib/web/src/web/cli.cr", 1 => "lib/dbx/src/dbx.cr", 2 => "src/a/x.cr"}.each do |line, target|
        r = c.request("textDocument/definition", {textDocument: {uri: u}, position: {line: line, character: 11}})
        defs = r.as_a? || [r]
        defs.map(&.["uri"].as_s).should contain(c.uri(target))
      end
    ensure
      c.cleanup
    end
  end
end
