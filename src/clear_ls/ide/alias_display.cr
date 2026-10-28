require "./typing"

module ClearLS::IDE
  # Alias names for display (Phase 12, F6). Inference expands aliases like
  # the compiler does (`alias Names = Array(String)`: `typeof` is
  # `Array(String)`); this layer remembers where a type was *written* as an
  # alias and spells it that way in hints and hover. Type identity is
  # untouched.
  #
  # A tag says "type node N is spelled `Name`" and applies at any depth
  # (`Array(Id)`, `Hash(String, Id)`). Tags come from written types (a
  # call's declared return type, a parameter's restriction, `x : T`,
  # `[] of T`) and flow with values: through assignments and reads, from
  # a call's receiver and arguments into its result (`xs.first` of an
  # `Array(Id)` is an `Id`), from a block's call into its parameters, and
  # through joins (`if`, `||`, `&&`) as long as every joined value that
  # contains the node carries the same name for it; a tagged node meeting
  # the same node untagged (`names` vs `["b"]`) is shown expanded.
  #
  # Approximation: a tag covers every occurrence of its node in a value's
  # type, so in `Hash(Int32 | String, Id)` with `alias Id = Int32 |
  # String` both parts print as `Id`.
  class AliasDisplay
    # Spelling per type node.
    alias Tags = Hash(Types::TyId, String)

    @memo = {} of HIR::ExprId => Tags?
    @binding_memo = {} of HIR::BindingId => Tags?
    @in_progress = Set(HIR::ExprId).new
    @binding_in_progress = Set(HIR::BindingId).new

    def initialize(@body : HIR::Body, @inf : Types::Infer, @typing : Typing, @ns : Semantics::TypeId)
    end

    # One pass over the body: assigned values per local, the assignment
    # of each target, the call of each block (by block range).
    @writes : Hash(HIR::BindingId, Array(HIR::ExprId))? = nil
    @assign_of = {} of HIR::ExprId => HIR::Expr
    @call_of_block = {} of TextRange => HIR::Expr

    private def writes : Hash(HIR::BindingId, Array(HIR::ExprId))
      @writes ||= begin
        w = {} of HIR::BindingId => Array(HIR::ExprId)
        blocks = {} of HIR::ExprId => TextRange
        @body.exprs.each { |x| blocks[x.id] = x.range if x.kind.block? }
        @body.exprs.each do |x|
          if (x.kind.assign? || x.kind.type_decl?) && (first = x.children.first?)
            @assign_of[first] = x
            if x.kind.assign? && x.children.size == 2
              target = @body.expr(first)
              if target.kind.local_ref? && (b = target.binding)
                (w[b] ||= [] of HIR::ExprId) << x.children[1]
              end
            end
          end
          if x.kind.call? && (blk = x.block) && (r = blocks[blk]?)
            @call_of_block[r] = x
          end
        end
        w
      end
    end

    private def table : Types::TypeTable
      @typing.table
    end

    # *t* spelled with *tags*, like `TypeTable#to_s` otherwise. Nil when no
    # tag applies.
    def render(t : Types::TyId, tags : Tags?) : String?
      return nil unless tags && !tags.empty?
      used = false
      s = String.build { |io| used = spell(t, tags, io) }
      used ? s : nil
    end

    # Writes *t*; true when some tag was used.
    private def spell(t : Types::TyId, tags : Tags, io : IO) : Bool
      if name = tags[t]?
        io << name
        return true
      end
      ty = table[t]
      case ty.kind
      when .union?
        spell_union(t, tags, io)
      when .named?
        io << table.def_map[ty.def_id.not_nil!].full_name
        return false if ty.args.empty?
        used = false
        io << '('
        ty.args.each_with_index { |a, i| io << ", " if i > 0; used |= spell(a, tags, io) }
        io << ')'
        used
      when .tuple?, .named_tuple?
        used = false
        io << '{'
        ty.args.each_with_index do |a, i|
          io << ", " if i > 0
          io << ty.names[i] << ": " if ty.kind.named_tuple?
          used |= spell(a, tags, io)
        end
        io << '}'
        used
      when .proc?
        used = false
        params = ty.args[0...-1]
        params.each_with_index { |a, i| io << ", " if i > 0; used |= spell(a, tags, io) }
        io << ' ' unless params.empty?
        io << "-> "
        used | spell(ty.args.last, tags, io)
      when .metaclass?
        inner = table[ty.args[0]]
        paren = inner.kind.union? || inner.kind.proc?
        io << '(' if paren
        used = spell(ty.args[0], tags, io)
        io << ')' if paren
        io << ".class"
        used
      else
        io << table.to_s(t)
        false
      end
    end

    # A union whose members include a tagged union alias's members
    # (`Int32 | String | Nil` with `Id` → `Id?`) spells it in place of
    # them, at the position of its first member.
    private def spell_union(t : Types::TyId, tags : Tags, io : IO) : Bool
      members = table.members(t)
      groups = tags.select { |n, _| n != t && table[n].kind.union? && table.members(n).all? { |m| members.includes?(m) } }
      parts = [] of {Types::TyId?, String?}
      done = Set(Types::TyId).new
      members.each do |m|
        next if done.includes?(m)
        if (g = groups.find { |n, _| table.members(n).includes?(m) })
          parts << {nil, g[1]}
          done.concat(table.members(g[0]))
        else
          parts << {m, nil}
        end
      end
      used = !groups.empty?
      nil_part = parts.find { |(m, _)| m && table.nil_type?(m) }
      rest = parts.reject { |p| p == nil_part }
      write = ->(p : {Types::TyId?, String?}) do
        if name = p[1]
          io << name
        else
          used |= spell(p[0].not_nil!, tags, io)
        end
      end
      if nil_part && rest.size == 1
        single = rest[0]
        paren = (m = single[0]) && table[m].kind.proc?
        io << '(' if paren
        write.call(single)
        io << ')' if paren
        io << '?'
      else
        parts.each_with_index { |p, i| io << " | " if i > 0; write.call(p) }
      end
      used
    end

    # Display of the value written to the assignment target *target* (the
    # `x` of `x = v`), or nil.
    def target(target : HIR::ExprId) : String?
      t = @inf.types[target]? || return nil
      writes
      parent = @assign_of[target]?
      if parent && parent.kind.assign?
        v = parent.children[1]? || return nil
        render(t, tags_of(v).try { |tags| restrict(tags, t) })
      else
        e = @body.expr(target)
        e.binding.try { |b| binding(b, t) }
      end
    end

    # Display of expression *id*'s value, or nil.
    def expr(id : HIR::ExprId) : String?
      t = @inf.types[id]? || return nil
      render(t, tags_of(id))
    end

    # Display of binding *b* when its type is *t* (a read narrowed by
    # flow, or the declaration's value).
    def binding(b : HIR::BindingId, t : Types::TyId) : String?
      render(t, binding_tags(b).try { |tags| restrict(tags, t) })
    end

    def tags_of(id : HIR::ExprId) : Tags?
      return @memo[id] if @memo.has_key?(id)
      return nil unless @in_progress.add?(id)
      tags = compute(id)
      @in_progress.delete(id)
      @memo[id] = tags
    end

    private def compute(id : HIR::ExprId) : Tags?
      e = @body.expr(id)
      t = @inf.types[id]? || return nil
      tags = case e.kind
             when .call?
               call_tags(e)
             when .local_ref?
               e.binding.try { |b| binding_tags(b) }
             when .assign?, .type_decl?
               e.kind.type_decl? ? decl_tags(e) : e.children[1]?.try { |v| tags_of(v) }
             when .seq?
               e.children.last?.try { |c| tags_of(c) }
             when .if?, .unless?
               join([e.children[1]?, e.children[2]?].compact)
             when .or?, .and?
               join(e.children)
             when .collection?
               # `[] of Id`, `{} of String => Id`, and the elements.
               written = [e.type_text, e.type_text2].compact.compact_map { |tt| written_tags(tt, @ns, [] of String) }
               union(written + e.children.compact_map { |c| tags_of(c) } + e.named_args.compact_map { |(_, v)| tags_of(v) })
             else
               nil
             end
      tags.try { |x| restrict(x, t) }
    end

    # Tags of the written return types of every candidate the call reaches,
    # plus what the receiver and arguments carry (a generic method's `T`
    # comes from them: `xs.first`, `h["k"]`).
    private def call_tags(e : HIR::Expr) : Tags?
      from_values = union(([e.receiver] + e.children).compact.compact_map { |c| inner_tags(c) })
      res = @inf.resolutions[e.id]?
      written = nil.as(Tags?)
      if res && !res.candidates.empty?
        all = res.candidates.compact_map do |c|
          sig = c.match.site.item.signature || next
          text = sig.return_type || next
          tparams = @typing.def_map[c.match.owner].type_params + sig.free_vars
          written_tags(text, c.match.owner, tparams)
        end
        written = all.size == res.candidates.size ? common(all) : nil
      end
      union([written, from_values].compact)
    end

    private def decl_tags(e : HIR::Expr) : Tags?
      b = e.binding || return nil
      binding_tags(b)
    end

    # Join of every write of a local (assignments, its declaration or
    # restriction); block arguments take what their call's receiver and
    # arguments carry.
    def binding_tags(b : HIR::BindingId) : Tags?
      return @binding_memo[b] if @binding_memo.has_key?(b)
      return nil unless @binding_in_progress.add?(b)
      bd = @body.binding(b)
      tags = if (r = bd.restriction) && (bd.kind.param? || bd.kind.type_decl?)
               written_tags(r, @ns, [] of String)
             elsif bd.kind.block_arg?
               block_arg_tags(bd)
             else
               values = writes[b]?
               values ? join(values) : nil
             end
      @binding_in_progress.delete(b)
      @binding_memo[b] = tags
    end

    private def block_arg_tags(bd : HIR::Binding) : Tags?
      writes
      call = @call_of_block[@body.scope(bd.scope).range]? || return nil
      union(([call.receiver] + call.children).compact.compact_map { |c| inner_tags(c) })
    end

    # What a value's type arguments are spelled as: what a generic method
    # can hand on (`xs.first` of `Array(Id)` is an `Id`). The value's own
    # spelling isn't: `names.map { }` builds a new `Array(String)`, not a
    # `Names`.
    private def inner_tags(id : HIR::ExprId) : Tags?
      tags = tags_of(id) || return nil
      t = @inf.types[id]? || return tags
      r = tags.reject { |n, _| n == t || (table[t].kind.union? && table.members(t).includes?(n)) }
      r.empty? ? nil : r
    end

    # Tags that every value containing the node agrees on; a value that
    # contains it untagged drops it (`names` meets `["b"]`).
    private def join(values : Array(HIR::ExprId)) : Tags?
      parts = values.map do |v|
        t = @inf.types[v]? || return nil
        {t, tags_of(v) || Tags.new}
      end
      result = Tags.new
      parts.each do |(_, tags)|
        tags.each do |n, name|
          next if result.has_key?(n)
          agree = parts.all? { |(t, tg)| !covers?(t, n) || tg[n]? == name }
          result[n] = name if agree
        end
      end
      result.empty? ? nil : result
    end

    # Every tag of any part; a node spelled two ways is dropped.
    private def union(parts : Array(Tags)) : Tags?
      result = Tags.new
      conflict = Set(Types::TyId).new
      parts.each do |tags|
        tags.each do |n, name|
          if (prev = result[n]?) && prev != name
            conflict << n
          else
            result[n] = name
          end
        end
      end
      conflict.each { |n| result.delete(n) }
      result.empty? ? nil : result
    end

    # Tags all candidates agree on.
    private def common(all : Array(Tags)) : Tags?
      first = all.first? || return nil
      result = first.select { |n, name| all.all? { |o| o[n]? == name } }
      result.empty? ? nil : result
    end

    private def restrict(tags : Tags, t : Types::TyId) : Tags?
      r = tags.select { |n, _| covers?(t, n) }
      r.empty? ? nil : r
    end

    # Does type *t* contain node *n* (anywhere; a union alias also inside
    # a larger union, which flattens it)?
    private def covers?(t : Types::TyId, n : Types::TyId) : Bool
      return true if t == n
      ty = table[t]
      if ty.kind.union? && table[n].kind.union?
        return true if table.members(n).all? { |m| ty.args.includes?(m) }
      end
      ty.args.any? { |a| covers?(a, n) }
    end

    NAME = /(?<![\w:])(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*/

    # Tags of a written type: every constant path in it that names an
    # alias tags the type the alias expands to.
    private def written_tags(text : String, ns : Semantics::TypeId, tparams : Array(String)) : Tags?
      tags = Tags.new
      text.scan(NAME) do |m|
        path = m[0]
        next if tparams.includes?(path)
        id = @typing.def_map.lookup_path_raw(path, ns) || next
        next unless @typing.def_map[id].kind.alias?
        t = Types::TypeExprParser.parse(path, table, ns, tparams)
        next if table.unknown?(t)
        tags[t] = path.lchop("::")
      end
      tags.empty? ? nil : tags
    end
  end
end
