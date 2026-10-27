# Types of `__t(expr)` marker arguments in FILEs as clear-ls infers them,
# printed like the compiler prints types (`@LINE Type`), for diffing with
# the output of the `__t` macro in tools/fixtures/book/src/h.cr:
#
#   bin/probes/type_marks ROOT FILE...
#   crystal build --no-codegen FILE    # prints the compiler's `@LINE Type`
#
# Unknown prints `?`. One line per marker (the compiler prints one per
# instantiation of the enclosing def).
require "../../src/clear_ls"
include ClearLS

root = ARGV[0]
proj = Workspace::Project.detect(root)
vfs = VFS.new
idx = Workspace::Index.new(proj, vfs)
::Log.setup(:error)
idx.load
# One Typing per program view (a stdlib file outside the project's
# require closure is a program of its own).
typings = {} of UInt64 => IDE::Typing
typing_for = ->(f : FileId) { m = idx.def_map_for(f); typings[m.object_id] ||= IDE::Typing.new(m, vfs) }

# Compiler spelling: `Tuple(A, B)`, `(A | B)` with sorted members,
# `Proc(A, R)`, `NamedTuple(x: A)`, `A.class`.
def cname(table : Types::TypeTable, map : Semantics::DefMap, id : Types::TyId, nested = false) : String
  t = table[id]
  case t.kind
  when .unknown?, .pending? then "?"
  when .no_return?          then "NoReturn"
  when .type_param?         then t.param.not_nil!
  when .named?
    name = map[t.def_id.not_nil!].full_name
    t.args.empty? ? name : "#{name}(#{t.args.map { |a| cname(table, map, a, true) }.join(", ")})"
  when .union?
    # Sorted, Nil last; parenthesised only at the top level.
    names = t.args.map { |a| cname(table, map, a, true) }.sort_by { |x| {x == "Nil" ? 1 : 0, x} }
    nested ? names.join(" | ") : "(#{names.join(" | ")})"
  when .tuple?      then "Tuple(#{t.args.map { |a| cname(table, map, a, true) }.join(", ")})"
  when .named_tuple?
    keys = t.names.map { |n| n =~ /\A[a-z_]\w*\z/ ? n : n.inspect }
    "NamedTuple(#{keys.zip(t.args).map { |(n, a)| "#{n}: #{cname(table, map, a, true)}" }.join(", ")})"
  when .proc?
    # The return type is a union in parentheses (`Proc((Int32 | String))`).
    parts = t.args.map_with_index { |a, i| cname(table, map, a, i < t.args.size - 1) }
    "Proc(#{parts.join(", ")})"
  when .metaclass?  then "#{cname(table, map, t.args[0])}.class"
  else                   "?"
  end
end

ARGV[1..].each do |path|
  path = File.expand_path(path)
  state = vfs.load(VFS.uri_for(path)).not_nil!
  typing = typing_for.call(state.id)
  table = typing.table
  map = typing.def_map
  bodies = IDE::Bodies.new(state)
  marks = [] of Syntax::Node
  state.tree.root.walk do |n|
    marks << n if n.kind.call? && n.field_text(Syntax::Field::Method) == "__t"
    true
  end
  marks.each do |n|
    line = state.text.byte_slice(0, n.start_byte).count('\n') + 1
    ty = "?"
    if hit = typing.infer_at(state, bodies, n.start_byte)
      body, inf = hit
      call = body.exprs.find { |e| e.kind.call? && e.name == "__t" && e.range.start == n.start_byte }
      if call && (arg = call.children[0]?)
        ty = cname(table, map, inf.type_of(arg))
      end
    end
    puts "@#{line} #{ty}"
  end
end
