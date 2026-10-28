require "./typing"

module ClearLS::IDE
  # Alias names for display (Phase 12, F6). Inference expands aliases like
  # the compiler does (`alias Names = Array(String)`: `typeof` is
  # `Array(String)`); this layer remembers where a type was *written* as an
  # alias and spells it that way in hints and hover. Type identity is
  # untouched.
  #
  # Tags come from written types: a call's declared return type, a
  # parameter's restriction, `x : T = v`. A value keeps its tags through
  # assignments, reads and joins (`if`, `||`, `&&`) as long as every
  # joined value that contributes a member carries the same alias for
  # it; a tagged member meeting the same member untagged (`names` vs
  # `["b"]`) is shown expanded.
  #
  # Only whole union parts are tracked (`Names`, `Names?`, `Names | Int32`),
  # not aliases nested in generic arguments (`Array(Names)`).
  class AliasDisplay
    # Spelling per union member of a value's type.
    alias Tags = Hash(Types::TyId, String)

    # Members each alias spelling stands for (`alias Stdio = Redirect |
    # IO`: both), to show the alias only when all of them are present.
    @groups = {} of String => Set(Types::TyId)
    @memo = {} of HIR::ExprId => Tags?
    @binding_memo = {} of HIR::BindingId => Tags?
    @in_progress = Set(HIR::ExprId).new
    @binding_in_progress = Set(HIR::BindingId).new

    def initialize(@body : HIR::Body, @inf : Types::Infer, @typing : Typing, @ns : Semantics::TypeId)
    end

    private def table : Types::TypeTable
      @typing.table
    end

    # *t* as shown: alias names where tags cover whole aliases, the rest
    # like `TypeTable#to_s`. Nil when no alias applies.
    def render(t : Types::TyId, tags : Tags?) : String?
      return nil unless tags && !tags.empty?
      members = table.members(t)
      shown = [] of String
      done = Set(String).new
      covered = Set(Types::TyId).new
      members.each do |m|
        next if table.nil_type?(m)
        if (s = tags[m]?) && (g = @groups[s]?) && g.all? { |x| members.includes?(x) && tags[x]? == s }
          shown << s if done.add?(s)
          covered.concat(g)
        end
      end
      return nil if shown.empty?
      rest = members.reject { |m| covered.includes?(m) || table.nil_type?(m) }
      has_nil = members.any? { |m| table.nil_type?(m) } && !covered.any? { |m| table.nil_type?(m) }
      parts = shown + rest.map { |m| table.to_s(m) }
      if has_nil && parts.size == 1
        "#{parts[0]}?"
      else
        parts << "Nil" if has_nil
        parts.join(" | ")
      end
    end

    # Display of the value written to the assignment target *target* (the
    # `x` of `x = v`), or nil.
    def target(target : HIR::ExprId) : String?
      t = @inf.types[target]? || return nil
      parent = @body.exprs.find { |x| (x.kind.assign? || x.kind.type_decl?) && x.children.first? == target }
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
               call_tags(e, t)
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
             else
               nil
             end
      tags.try { |x| restrict(x, t) }
    end

    # Tags of the written return types of every candidate the call reaches.
    private def call_tags(e : HIR::Expr, t : Types::TyId) : Tags?
      res = @inf.resolutions[e.id]? || return nil
      return nil if res.candidates.empty?
      all = res.candidates.map do |c|
        sig = c.match.site.item.signature || return nil
        text = sig.return_type || return nil
        tparams = @typing.def_map[c.match.owner].type_params + sig.free_vars
        written_tags(text, c.match.owner, tparams) || return nil
      end
      merge(all)
    end

    private def decl_tags(e : HIR::Expr) : Tags?
      b = e.binding || return nil
      binding_tags(b)
    end

    # Join of every write of a local (assignments, its declaration or
    # restriction).
    def binding_tags(b : HIR::BindingId) : Tags?
      return @binding_memo[b] if @binding_memo.has_key?(b)
      return nil unless @binding_in_progress.add?(b)
      bd = @body.binding(b)
      tags = if (r = bd.restriction) && (bd.kind.param? || bd.kind.type_decl?)
               # Written: the restriction is the type (narrowed per read).
               written_tags(r, @ns, [] of String)
             else
               values = [] of HIR::ExprId
               @body.exprs.each do |x|
                 next unless x.kind.assign? && x.children.size == 2
                 target = @body.expr(x.children[0])
                 values << x.children[1] if target.kind.local_ref? && target.binding == b
               end
               values.empty? ? nil : join(values)
             end
      @binding_in_progress.delete(b)
      @binding_memo[b] = tags
    end

    # Per member: the common spelling of every value that has the member;
    # untagged anywhere → untagged. Values without tags count as untagged
    # for their members (`names` meets `["b"]`).
    private def join(values : Array(HIR::ExprId)) : Tags?
      parts = values.map do |v|
        t = @inf.types[v]? || return nil
        {table.members(t), tags_of(v) || Tags.new}
      end
      result = Tags.new
      seen = Set(Types::TyId).new
      parts.each do |(members, _)|
        members.each do |m|
          next unless seen.add?(m)
          spellings = parts.select { |(ms, _)| ms.includes?(m) }.map { |(_, tg)| tg[m]? }
          s = spellings.first?
          result[m] = s.not_nil! if s && spellings.all?(&.==(s))
        end
      end
      result.empty? ? nil : result
    end

    private def merge(all : Array(Tags)) : Tags?
      return all.first? if all.size <= 1
      first = all.first
      result = Tags.new
      first.each { |m, s| result[m] = s if all.all? { |o| o[m]? == s } }
      result.empty? ? nil : result
    end

    private def restrict(tags : Tags, t : Types::TyId) : Tags?
      members = table.members(t)
      r = tags.select { |m, _| members.includes?(m) }
      r.empty? ? nil : r
    end

    PATH = /\A(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*\z/

    # Tags of a written type: each top-level union part that names an
    # alias (`Names`, `Names?`) tags the members it expands to.
    private def written_tags(text : String, ns : Semantics::TypeId, tparams : Array(String)) : Tags?
      tags = Tags.new
      split_union(text).each do |part|
        part = part.strip
        part = part.rchop('?').rstrip if part.ends_with?('?')
        next unless part.matches?(PATH)
        id = @typing.def_map.lookup_path_raw(part, ns) || next
        next unless @typing.def_map[id].kind.alias?
        t = Types::TypeExprParser.parse(part, table, ns, tparams)
        next if table.unknown?(t)
        name = part.lchop("::")
        group = table.members(t).to_set
        @groups[name] = group
        group.each { |m| tags[m] = name }
      end
      tags.empty? ? nil : tags
    end

    private def split_union(text : String) : Array(String)
      parts = [] of String
      depth = 0
      start = 0
      text.each_char_with_index do |c, i|
        case c
        when '(', '{', '[' then depth += 1
        when ')', '}', ']' then depth -= 1
        when '|'
          if depth == 0
            parts << text[start...i]
            start = i + 1
          end
        end
      end
      parts << text[start..]
      parts
    end
  end
end
