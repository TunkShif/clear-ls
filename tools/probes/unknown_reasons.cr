# Classifies why locals stay unknown, by the value of their first
# assignment (unknown receiver, def without return type, ...), with samples.
#
#   bin/probes/unknown_reasons ROOT PREFIX
require "../../src/clear_ls"
include ClearLS
root = ARGV[0]
proj = Workspace::Project.detect(root)
vfs = VFS.new
idx = Workspace::Index.new(proj, vfs)
::Log.setup(:error)
idx.load
typing = IDE::Typing.new(idx.def_map, vfs)
table = typing.table
files = [] of String
idx.each_entry { |id, e| files << e.path if e.path.starts_with?(ARGV[1]) }
reasons = Hash(String, Int32).new(0)
samples = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }
files.sort.each do |path|
  state = vfs.load(VFS.uri_for(path)).not_nil!
  bodies = IDE::Bodies.new(state)
  nodes = [] of Syntax::Node
  state.tree.root.walk { |n| nodes << n if n.kind.method_def?; true }
  nodes.each do |n|
    body, inf = typing.infer_at(state, bodies, n.start_byte + 1).not_nil!
    body.bindings.each do |b|
      next unless b.kind.local?
      next unless table.unknown?(inf.binding_type(b.id))
      assign = body.exprs.find { |e| (e.kind.assign? || e.kind.op_assign?) && e.children[0]?.try { |c| body.expr(c).binding == b.id } }
      reason = "other"
      if assign && (v = assign.children[1]?)
        ve = body.expr(v)
        if ve.kind.call?
          res = inf.resolutions[ve.id]?
          recv_unknown = ve.receiver.try { |r| table.unknown?(inf.type_of(r)) } || false
          if recv_unknown
            reason = "call: receiver unknown"
          elsif res.nil? || res.family.empty?
            reason = "call: unresolved name"
          elsif res.candidates.empty?
            reason = "call: no viable overload"
          elsif res.candidates.any? { |c| c.signature.try(&.return_type).nil? }
            reason = "call: viable def without return type"
          else
            reason = "call: declared return not substitutable"
          end
        else
          reason = "value: #{ve.kind}"
        end
      elsif assign.nil?
        reason = "no simple assignment"
      end
      reasons[reason] += 1
      if samples[reason].size < 4
        line = state.text.byte_slice(0, b.name_range.start).count('\n')
        samples[reason] << "#{File.basename(path)}:#{line + 1} #{state.text.lines[line].strip[0, 80]}"
      end
    end
  end
end
reasons.to_a.sort_by(&.[1]).reverse.each do |(r, n)|
  puts "#{n.to_s.rjust(5)} #{r}"
  samples[r].each { |s| puts "        #{s}" }
end
