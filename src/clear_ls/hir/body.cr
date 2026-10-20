require "./expr"

module ClearLS::HIR
  # Lowered body of one `def` (or other executable item).
  #
  # Arena-based: `exprs`, `bindings`, `scopes` are indexed by their IDs.
  # The source map goes both ways: expression/binding → range is stored on
  # the node; range → node uses the sorted span index (`#expr_at`).
  class Body
    getter range : TextRange
    getter root : ExprId
    getter exprs : Array(Expr)
    getter bindings : Array(Binding)
    getter scopes : Array(Scope)
    @spans : Array({TextRange, ExprId})? = nil

    def initialize(@range, @root, @exprs, @bindings, @scopes)
    end

    def expr(id : ExprId) : Expr
      @exprs[id.value]
    end

    def binding(id : BindingId) : Binding
      @bindings[id.value]
    end

    def scope(id : ScopeId) : Scope
      @scopes[id.value]
    end

    # Innermost scope containing *offset*.
    def scope_at(offset : UInt32) : ScopeId
      best = ScopeId.new(0)
      best_size = UInt32::MAX
      @scopes.each do |s|
        if s.range.touches?(offset) && s.range.size <= best_size
          best, best_size = s.id, s.range.size
        end
      end
      best
    end

    # Bindings visible at *offset*: the scope chain at that point, filtered
    # to bindings whose declaring name ends at or before *offset* (Crystal
    # locals are positional). Inner bindings shadow outer ones of the same
    # name.
    def visible_bindings(offset : UInt32) : Array(Binding)
      seen = Set(String).new
      result = [] of Binding
      sid = scope_at(offset).as(ScopeId?)
      while id = sid
        s = scope(id)
        s.bindings.each_value do |bid|
          b = binding(bid)
          next unless b.name_range.end <= offset
          result << b if seen.add?(b.name)
        end
        sid = s.parent
      end
      result
    end

    # Binding whose declaration or reference covers *offset*.
    def binding_at(offset : UInt32) : {Binding, Reference}?
      @bindings.each do |b|
        b.references.each do |r|
          return {b, r} if r.range.touches?(offset)
        end
      end
      nil
    end

    # Smallest expression covering *offset*.
    def expr_at(offset : UInt32) : Expr?
      spans = @spans ||= @exprs.map { |e| {e.range, e.id} }.sort_by! { |(r, _)| {r.size, r.start} }
      spans.each do |(r, id)|
        return expr(id) if r.touches?(offset)
      end
      nil
    end
  end
end
