# Builds the CFG of every def in DIR (crash check + timing).
#
#   bin/probes/cfg_all DIR
require "../../src/clear_ls"
include ClearLS
dir = ARGV[0]
parser = Syntax::Parser.new
files = Dir.glob("#{dir}/**/*.cr")
defs = 0; blocks = 0; lower_t = Time::Span.zero; build_t = Time::Span.zero
files.each do |f|
  tree = parser.parse(File.read(f))
  nodes = [] of Syntax::Node
  tree.root.walk { |n| nodes << n if n.kind.method_def?; true }
  nodes.each do |n|
    t0 = Time.instant
    body = HIR::LowerBody.lower(n)
    t1 = Time.instant
    cfg = Flow::Builder.build(body)
    build_t += Time.instant - t1
    lower_t += t1 - t0
    defs += 1; blocks += cfg.blocks.size
  rescue ex
    STDERR.puts "#{f}:#{n.start_byte}: #{ex.message}"
  end
end
puts "#{files.size} files, #{defs} defs, #{blocks} blocks; lower #{lower_t.total_milliseconds.round}ms, cfg #{build_t.total_milliseconds.round}ms"
