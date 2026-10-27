# What a workspace reference index would contain: for every def body of
# indexed files under PREFIX, how its calls and constant paths resolve,
# and how long body inference over the whole set takes.
#
#   bin/probes/refs_probe ROOT PREFIX     e.g. bin/probes/refs_probe $PWD $PWD/src
#
# Prints call resolutions by kind (unique / runtime-targets / ambiguous /
# name-only / unresolved), constant references resolved, and timings.
# `SHOW=kind` samples call sites of one resolution kind.
require "../../src/clear_ls"
root = ARGV[0]
proj = ClearLS::Workspace::Project.detect(root)
vfs = ClearLS::VFS.new
idx = ClearLS::Workspace::Index.new(proj, vfs)
idx.load
map = idx.def_map
typing = ClearLS::IDE::Typing.new(map, vfs)
kinds = Hash(String, Int32).new(0)
receiverless = Hash(String, Int32).new(0)
consts = Hash(String, Int32).new(0)
show = ENV["SHOW"]?
defs = 0
bodies_n = 0
files = [] of String
idx.each_entry { |_, e| files << e.path if e.path.starts_with?(ARGV[1]) }
lower_t = Time::Span.zero
t = Time.measure do
  files.sort.each do |path|
    state = vfs.load(ClearLS::VFS.uri_for(path)).not_nil!
    bodies = ClearLS::IDE::Bodies.new(state)
    starts = [0_u32]
    state.tree.root.walk { |n| starts << n.start_byte + 1 if n.kind.method_def?; true }
    done = Set(UInt32).new
    starts.each do |s|
      t0 = Time.instant
      body = bodies.at(s) || next
      lower_t += t0.elapsed
      next unless done.add?(body.range.start)
      bodies_n += 1
      defs += 1 unless s == 0
      _, inf = typing.infer_at(state, bodies, s).not_nil!
      ns = map.namespace_at(state.id, body.range.start)
      body.exprs.each do |e|
        if e.kind.call?
          res = inf.resolutions[e.id]?
          k = res ? res.kind.to_s : "NotEvaluated"
          kinds[k] += 1
          receiverless[k] += 1 if e.receiver.nil?
          if show && k == show && rand < 0.02
            line = state.text.byte_slice(0, e.range.start).count('\n')
            puts "  #{File.basename(path)}:#{line + 1} #{e.name}: #{state.text.lines[line].strip[0, 80]}"
          end
        elsif e.kind.const?
          name = e.name || next
          consts[map.lookup_path(name, ns) ? "type" : "other"] += 1
        end
      end
    end
  end
end
total = kinds.values.sum
puts "files=#{files.size} bodies=#{bodies_n} defs=#{defs} time=#{t.total_seconds.round(2)}s (lowering #{lower_t.total_seconds.round(2)}s)"
puts "calls=#{total}"
kinds.to_a.sort_by(&.[1]).reverse.each do |(k, n)|
  puts "  #{k.ljust(24)} #{n.to_s.rjust(7)} #{(100.0 * n / total).round(1).to_s.rjust(5)}%  (receiverless #{receiverless[k]})"
end
puts "const paths: #{consts}"

# Name-filtered lookup: for each NAMES entry, infer only the bodies whose
# text contains the word (cold Typing per name), count resolved calls.
(ENV["NAMES"]? || "infer_at,def_map,lookup_path,size,each").split(',').each do |name|
  ty = ClearLS::IDE::Typing.new(map, vfs)
  word = /(?<![\w@])#{Regex.escape(name)}(?![\w])/
  hits = 0; cand_files = 0; cand_bodies = 0; exact = 0; loose = 0
  elapsed = Time.measure do
    files.each do |path|
      text = File.read(path)
      next unless text.matches?(word)
      cand_files += 1
      state = vfs.load(ClearLS::VFS.uri_for(path)).not_nil!
      bodies = ClearLS::IDE::Bodies.new(state)
      seen = Set(UInt32).new
      text.scan(word) do |m|
        off = m.byte_begin(0).to_u32
        body = bodies.at(off) || next
        next unless seen.add?(body.range.start)
        cand_bodies += 1
        _, inf = ty.infer_at(state, bodies, off).not_nil!
        body.exprs.each do |e|
          next unless e.kind.call? && e.name == name
          hits += 1
          res = inf.resolutions[e.id]?
          if res && (res.kind.unique? || res.kind.multiple_runtime_targets?)
            exact += 1
          else
            loose += 1
          end
        end
      end
    end
  end
  puts "refs #{name.ljust(12)} files=#{cand_files} bodies=#{cand_bodies} calls=#{hits} resolved=#{exact} unresolved/ambiguous=#{loose} #{elapsed.total_milliseconds.round}ms"
end
