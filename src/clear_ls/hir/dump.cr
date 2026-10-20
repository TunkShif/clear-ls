require "./body"

module ClearLS::HIR
  # Debug dump: bindings with their references, then the expression tree.
  module Dump
    def self.dump(body : Body, index : LineIndex, io : IO) : Nil
      body.scopes.each do |s|
        io << "scope#" << s.id.value << ' ' << s.kind.to_s.downcase
        io << " parent=#" << s.parent.not_nil!.value if s.parent
        io << " @" << index.point(s.range.start) << '\n'
      end
      body.bindings.each do |b|
        io << "binding#" << b.id.value << ' ' << b.name << " (" << b.kind.to_s.downcase << ") scope#" << b.scope.value
        io << " : " << b.restriction if b.restriction
        io << " refs:"
        b.references.each { |r| io << ' ' << r.kind.to_s.downcase[0] << '@' << index.point(r.range.start) }
        io << '\n'
      end
      expr(body, body.root, index, 0, io)
    end

    private def self.expr(body : Body, id : ExprId, index : LineIndex, depth : Int32, io : IO) : Nil
      e = body.expr(id)
      io << "  " * depth << e.kind.to_s.downcase
      io << ' ' << e.name if e.name
      io << " →binding#" << e.binding.not_nil!.value if e.binding
      io << " @" << index.point(e.range.start) << '\n'
      e.receiver.try { |r| io << "  " * (depth + 1) << "receiver:\n"; expr(body, r, index, depth + 2, io) }
      e.children.each { |c| expr(body, c, index, depth + 1, io) }
      e.named_args.each { |(n, v)| io << "  " * (depth + 1) << n << ":\n"; expr(body, v, index, depth + 2, io) }
      e.block.try { |b| io << "  " * (depth + 1) << "block:\n"; expr(body, b, index, depth + 2, io) }
    end
  end
end
