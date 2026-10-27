# Inference coverage: share of locals and block args with a known type in
# every def of indexed files under PREFIX.
#
#   bin/probes/coverage ROOT PREFIX     e.g. bin/probes/coverage $PWD $PWD/src
#
# ENV: N=files limit, SHOW=1 samples unknown locals. Also lists defs slower
# than 5 ms.
require "../../src/clear_ls"
root = ARGV[0]
proj = ClearLS::Workspace::Project.detect(root)
vfs = ClearLS::VFS.new
idx = ClearLS::Workspace::Index.new(proj, vfs)
idx.load
# One Typing per program view (a stdlib file outside the project's
# require closure is a program of its own).
typings = {} of UInt64 => ClearLS::IDE::Typing
typing_for = ->(f : ClearLS::FileId) { m = idx.def_map_for(f); typings[m.object_id] ||= ClearLS::IDE::Typing.new(m, vfs) }
SLOW = [] of {Float64, String}
reasons = Hash(String, Int32).new(0)
known = 0; total = 0; defs = 0
files = [] of String
idx.each_entry { |id, e| files << e.path if e.path.starts_with?(ARGV[1]) }
t = Time.measure do
  files.sort.first(ENV["N"]?.try(&.to_i) || 100000).each do |path|
    state = vfs.load(ClearLS::VFS.uri_for(path)).not_nil!
    typing = typing_for.call(state.id)
    table = typing.table
    bodies = ClearLS::IDE::Bodies.new(state)
    nodes = [] of ClearLS::Syntax::Node
    state.tree.root.walk { |n| nodes << n if n.kind.method_def?; true }
    nodes.each do |n|
      defs += 1
      t0 = Time.instant
      body, inf = typing.infer_at(state, bodies, n.start_byte + 1).not_nil!
      dt = t0.elapsed
      SLOW << {dt.total_milliseconds, "#{File.basename(path)}:#{state.text.byte_slice(0, n.start_byte).count('\n') + 1}"} if dt.total_milliseconds > 5
      body.bindings.each do |b|
        next unless b.kind.local? || b.kind.block_arg?
        total += 1
        if table.unknown?(inf.binding_type(b.id))
          reasons[b.kind.block_arg? ? "block arg" : "local"] += 1
          if ENV["SHOW"]? && rand < 0.08
            line = state.text.byte_slice(0, b.name_range.start).count('\n')
            STDOUT.puts "  #{File.basename(path)}:#{line + 1} #{b.name}: #{state.text.lines[line].strip[0, 90]}"
          end
        else
          known += 1
        end
      end
    end
  end
end
puts "defs=#{defs} locals+blockargs=#{total} typed=#{known} (#{(100.0 * known / total).round(1)}%) time=#{t.total_seconds.round(2)}s unknown=#{reasons}"

SLOW.sort_by(&.[0]).reverse.first(10).each { |x| puts x }
puts "slow defs: #{SLOW.size}, total ms: #{SLOW.sum(&.[0]).round}"
