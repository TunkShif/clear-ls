require "./spec_helper"

# The CLI binary (bin/clear-ls, `make` builds it before specs).
private def cli(args : Array(String)) : {Int32, String, String}
  bin = File.expand_path("../bin/clear-ls", __DIR__)
  stdout, stderr = IO::Memory.new, IO::Memory.new
  st = Process.run(bin, args, output: stdout, error: stderr)
  {st.exit_code, stdout.to_s, stderr.to_s}
end

describe "clear-ls CLI" do
  it "reports user errors in one line without a trace" do
    [
      {["dump-items", "/nonexistent.cr"], "clear-ls: /nonexistent.cr: no such file"},
      {["dump-hir", __FILE__, "abc"], %(clear-ls: dump-hir: LINE must be a number, got "abc")},
      {["dump-hir", __FILE__], "clear-ls: dump-hir: missing LINE"},
      {["dump-cst", __DIR__], "clear-ls: #{__DIR__}: is a directory"},
      {["frob"], "clear-ls: unknown command frob (see --help)"},
      {["--bogus"], "clear-ls: unknown option --bogus (see --help)"},
      {["--log-level", "loud"], "clear-ls: unknown log level loud (trace, debug, info, warn, error)"},
    ].each do |(args, message)|
      code, _, err = cli(args)
      code.should eq 2
      err.lines.should eq [message]
    end
  end
end
