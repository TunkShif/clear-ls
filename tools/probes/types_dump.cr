# Every local / block arg as `file:line name type` (`?` = unknown), for
# regression diffs across commits (see tools/types_diff.py).
#
#   bin/probes/types_dump ROOT PREFIX > out.txt
#
# Build the old revision in a `git worktree`, never with
# `git checkout REV -- src` (it overwrites uncommitted work).
require "../../src/clear_ls"
root = ARGV[0]
proj = ClearLS::Workspace::Project.detect(root)
vfs = ClearLS::VFS.new
idx = ClearLS::Workspace::Index.new(proj, vfs)
::Log.setup(:error)
idx.load
typing = ClearLS::IDE::Typing.new(idx.def_map, vfs)
files = [] of String
idx.each_entry { |id, e| files << e.path if e.path.starts_with?(ARGV[1]) }
files.sort.each do |path|
  state = vfs.load(ClearLS::VFS.uri_for(path)).not_nil!
  bodies = ClearLS::IDE::Bodies.new(state)
  nodes = [] of ClearLS::Syntax::Node
  state.tree.root.walk { |n| nodes << n if n.kind.method_def?; true }
  nodes.each do |n|
    body, inf = typing.infer_at(state, bodies, n.start_byte + 1).not_nil!
    body.bindings.each do |b|
      next unless b.kind.local? || b.kind.block_arg?
      line = state.text.byte_slice(0, b.name_range.start).count('\n') + 1
      puts "#{path.sub(ARGV[1], "")}:#{line} #{b.name} #{typing.table.to_s(inf.binding_type(b.id))}"
    end
  end
end
