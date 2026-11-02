require "../spec_helper"
require "file_utils"

include ClearLS::Compiler

# Recorded from Crystal 1.22 (`crystal build --no-codegen -f json`).
private INSTANTIATION = %([{"file":"/w/src/p7.cr","line":19,"column":3,"size":5,"message":"instantiating 'Foo#greet(String)'"},{"file":"/w/src/p7.cr","line":6,"column":9,"size":0,"message":"expected argument #1 to 'String#+' to be Char or String, not Int32\\n\\nOverloads are:\\n - String#+(other : self)\\n - String#+(char : Char)"}])
private MACRO = %([{"file":"/w/src/mac.cr","line":4,"column":1,"size":3,"message":"expanding macro"},{"file":"/w/src/mac.cr","line":4,"column":1,"size":0,"message":"expanding macro"},{"file":"/w/src/mac.cr","line":1,"column":5,"size":4,"message":"undefined method 'nope' for Int32"}])
private SYNTAX = %([{"file":"/w/src/p7.cr","line":2,"column":3,"size":null,"message":"unexpected token: \\"1\\""}])
private WARNINGS = <<-TEXT
  In src/two.cr:3:1

   3 | old
       ^--
  Warning: Deprecated ::old. x

  In /abs/two.cr:4:1

   4 | old
       ^--
  Warning: Deprecated ::old. x

  A total of 2 warnings were found.
  TEXT

describe Output do
  it "takes the last frame as the error and keeps the trace" do
    frames = Output.error_frames("Showing last frame.\n" + INSTANTIATION + "\n").not_nil!
    frames.size.should eq 2
    err = Output.error(frames).not_nil!
    err.severity.should eq Severity::Error
    err.frame.line.should eq 6
    err.frame.column.should eq 9
    err.message.should start_with "expected argument #1 to 'String#+'"
    err.trace.map(&.line).should eq [19]
  end

  it "reports macro expansion errors at the call site" do
    err = Output.error(Output.error_frames(MACRO).not_nil!).not_nil!
    {err.frame.line, err.frame.column, err.frame.size}.should eq({4, 1, 3})
    err.message.should eq "undefined method 'nope' for Int32"
    err.trace.should be_empty
  end

  it "accepts null sizes" do
    err = Output.error(Output.error_frames(SYNTAX).not_nil!).not_nil!
    err.frame.size.should be_nil
    err.frame.line.should eq 2
  end

  it "returns nil without a JSON array" do
    Output.error_frames("Error: Error opening file with mode 'r': 'x.cr'").should be_nil
  end

  it "parses text warnings" do
    ws = Output.warnings(WARNINGS, "/w")
    ws.map { |w| {w.file, w.frame.line, w.frame.column, w.frame.size} }.should eq [
      {"/w/src/two.cr", 3, 1, 3},
      {"/abs/two.cr", 4, 1, 3},
    ]
    ws.first.severity.should eq Severity::Warning
    ws.first.message.should eq "Deprecated ::old. x"
  end
end

describe EntryPoints do
  it "reads shard targets and picks the ones whose closure has the file" do
    root = File.tempname("clear-ls-entry")
    Dir.mkdir_p(File.join(root, "src"))
    File.write(File.join(root, "shard.yml"), "name: x\ntargets:\n  a:\n    main: src/a.cr\n  b:\n    main: src/b.cr\n  gone:\n    main: src/nope.cr\n")
    a, b, shared, solo = %w(a b shared solo).map { |n| File.join(root, "src", "#{n}.cr") }
    [a, b, shared, solo].each { |f| File.write(f, "") }
    requires = {a => [shared], b => [] of String, shared => [] of String}
    ep = EntryPoints.new(root)
    ep.targets.should eq [a, b]
    ep.for(shared) { |p| requires[p]? }.should eq [a]
    ep.for(b) { |p| requires[p]? }.should eq [b]
    ep.for(solo) { |p| requires[p]? }.should eq [solo]
  ensure
    FileUtils.rm_rf(root) if root
  end
end

describe Job do
  it "collects output and exit status" do
    r = Job.new("sh", ["-c", "echo out; echo err >&2; exit 3"]).wait
    {r.exit_code, r.stdout, r.stderr}.should eq({3, "out\n", "err\n"})
    r.completed?.should be_true
    r.success?.should be_false
  end

  it "kills on timeout and on cancel" do
    r = Job.new("sleep", ["5"], timeout: 50.milliseconds).wait
    r.timed_out.should be_true
    r.completed?.should be_false
    r.elapsed.should be < 2.seconds

    job = Job.new("sleep", ["5"])
    spawn { sleep 20.milliseconds; job.cancel }
    r = job.wait
    r.cancelled.should be_true
    r.elapsed.should be < 2.seconds
  end

  it "reports a missing executable" do
    r = Job.new("/nonexistent/crystal", ["--version"]).wait
    r.launch_error.should_not be_nil
    r.completed?.should be_false
  end
end

describe Toolchain do
  # The one spec that runs the real compiler (~0.5 s).
  it "checks a program with the installed crystal" do
    root = File.tempname("clear-ls-tc")
    Dir.mkdir_p(root)
    # The compiler reports real paths (macOS: /var is /private/var).
    root = File.realpath(root)
    File.write(File.join(root, "bad.cr"), "def bar\n  1.nope\nend\nbar\n")
    tc = Toolchain.new(ENV["CRYSTAL"]? || "crystal", root)
    result = tc.check("bad.cr").wait
    result.completed?.should be_true
    problems = Toolchain.problems(result, root)
    problems.size.should eq 1
    p = problems.first
    {p.file, p.frame.line, p.frame.column}.should eq({File.join(root, "bad.cr"), 2, 5})
    p.message.should eq "undefined method 'nope' for Int32"
  ensure
    FileUtils.rm_rf(root) if root
  end
end

describe Exporter::Facts do
  it "parses methods and ivars, and marks unfinished sections" do
    text = "noise\nclear-ls:M\tFoo\tfalse\tpublic\t/w/a.cr:3:5\tbar(x : Int32) : String\nclear-ls:M\t\ttrue\tprivate\t/w/b.cr:1:1\tbaz()\nclear-ls:MEND\nclear-ls:I\tFoo\t@x\t(Int32 | Nil)\n"
    facts = Exporter::Facts.parse(text)
    ms = facts.methods.not_nil!
    ms.map { |m| {m.owner, m.class_level, m.visibility, m.file, m.line, m.column, m.header} }.should eq [
      {"Foo", false, "public", "/w/a.cr", 3, 5, "bar(x : Int32) : String"},
      {"", true, "private", "/w/b.cr", 1, 1, "baz()"},
    ]
    facts.ivars.should be_nil # no IEND: the compile stopped before typing ivars
    Exporter::Facts.parse("clear-ls:MEND\nclear-ls:IEND\n").ivars.should eq [] of Exporter::IvarFact
  end
end

describe ClearLS::Workspace::CompilerFacts do
  it "adds only members missing from source" do
    text = "class Foo\n  getter a : Int32\n  {% for n in %w(b) %}\n    def {{n.id}}; end\n  {% end %}\n  def c; end\nend\n"
    tree = ClearLS::Items::Lower.lower(ClearLS::Syntax::Parser.new.parse(text))
    map = ClearLS::Semantics::DefMap.new
    file = ClearLS::FileId.new(0)
    map.add_file(file, tree)
    facts = ClearLS::Workspace::CompilerFacts.new([
      Exporter::MethodFact.new("Foo", false, "public", "/w/a.cr", 2, 3, "a() : Int32"),
      Exporter::MethodFact.new("Foo", false, "public", "/w/a.cr", 3, 3, "b()"),
      Exporter::MethodFact.new("Foo", false, "public", "/w/a.cr", 6, 3, "c()"),
      Exporter::MethodFact.new("Nope", false, "public", "/w/a.cr", 6, 3, "d()"),
    ], [
      Exporter::IvarFact.new("Foo", "@a", "Int32"),
      Exporter::IvarFact.new("Foo", "@z", "String"),
    ])
    facts.apply(map, ->(_p : String) { file }, ->(_p : String) { text.as(String?) }).should eq 2
    foo = map[map.lookup_path("Foo").not_nil!]
    foo.members["b"].first.item.origin.compiler?.should be_true
    foo.members["b"].first.item.range.should eq ClearLS::TextRange.new(text.index!("{%").to_u32, text.index!("{%").to_u32 + 1)
    foo.members["a"].size.should eq 1
    foo.members["c"].size.should eq 1
    foo.members["@z"].first.item.detail.should eq "String"
  end
end

describe "ClearLS::Workspace::CompilerFacts digests" do
  it "skips files changed since the facts were taken" do
    text = "class Foo\n  {% for n in %w(b) %}\n    def {{n.id}}; end\n  {% end %}\nend\n"
    map = ClearLS::Semantics::DefMap.new
    file = ClearLS::FileId.new(0)
    map.add_file(file, ClearLS::Items::Lower.lower(ClearLS::Syntax::Parser.new.parse(text)))
    m = [Exporter::MethodFact.new("Foo", false, "public", "/w/a.cr", 2, 3, "b()")]
    stale = ClearLS::Workspace::CompilerFacts.new(m, [] of Exporter::IvarFact, {"/w/a.cr" => ClearLS::StableHash.hash("old")})
    stale.apply(map, ->(_p : String) { file }, ->(_p : String) { text.as(String?) }).should eq 0
    fresh = ClearLS::Workspace::CompilerFacts.new(m, [] of Exporter::IvarFact, {"/w/a.cr" => ClearLS::StableHash.hash(text)})
    fresh.apply(map, ->(_p : String) { file }, ->(_p : String) { text.as(String?) }).should eq 1
  end
end
