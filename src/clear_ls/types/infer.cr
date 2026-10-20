require "../hir"
require "../workspace/index"
require "./type_expr"

module ClearLS::Types
  # Where a def lives, for return-type parsing and `self`.
  record DefContext, ns : Semantics::TypeId, self_type : TyId, type_params : Array(String)

  # Candidate methods for a call on a receiver type.
  record MethodMatch, site : Semantics::Site, owner : Semantics::TypeId, bindings : Hash(String, TyId)

  # Phase-3 local type inference over one body.
  #
  # A single forward pass with an environment `HIR::BindingId → TyId`:
  # assignments update it, `if`/`case`/`while` join branch environments as
  # unions (no CFG yet: see Phase 4), and blocks are analysed in place with
  # block args typed from the called method's block restriction.
  #
  # Sources of types: literals, `T.new` (and `T.new` overloads with declared
  # return types), parameter restrictions, defaults, `as`/`uninitialized`,
  # declared return types of resolved methods (with generic substitution
  # from the receiver), ivar declarations, and accessor macros.
  #
  # Unknown stays Unknown: no guessing from names.
  class Infer
    getter types : Hash(HIR::ExprId, TyId)
    getter binding_types : Hash(HIR::BindingId, TyId)
    # Types of `yield` arguments seen in this body, per position.
    getter yield_types = [] of Array(TyId)

    MAX_UNION = 8

    # Loads a def's source (body lowering for yield summaries). Provided by
    # the caller; returns nil when the file cannot be read.
    alias SourceLoader = Proc(Semantics::Site, Syntax::Node?)
    property source_loader : SourceLoader? = nil
    # Remaining depth for nested summaries (yield types of called methods).
    property summary_depth = 1

    @env = {} of HIR::BindingId => TyId

    def initialize(@body : HIR::Body, @ctx : DefContext, @table : TypeTable)
      @types = {} of HIR::ExprId => TyId
      @binding_types = {} of HIR::BindingId => TyId
    end

    def map : Semantics::DefMap
      @table.def_map
    end

    def run : self
      seed_params
      visit(@body.root)
      self
    end

    def type_of(id : HIR::ExprId) : TyId
      @types[id]? || @table.unknown
    end

    # Join of every type assigned to *b* in this body (hover on the
    # declaration, inlay hints).
    def binding_type(b : HIR::BindingId) : TyId
      @binding_types[b]? || @table.unknown
    end

    # -- params ---------------------------------------------------------------

    private def seed_params : Nil
      @body.bindings.each do |b|
        next unless b.kind.param? || b.kind.block_param?
        ty = if r = b.restriction
               parse_type(r)
             else
               @table.unknown
             end
        # Splats: `*args : T` is a Tuple of T, `**opts` a NamedTuple.
        decl = param_decl_text(b)
        if decl.starts_with?("**")
          ty = @table.named?("NamedTuple") || @table.unknown
        elsif decl.starts_with?('*')
          ty = r ? (@table.named?("Tuple", [ty]) || @table.unknown) : (@table.named?("Tuple") || @table.unknown)
        elsif b.kind.block_param?
          ty = r ? ty : (@table.named?("Proc") || @table.unknown)
        end
        assign(b.id, ty)
      end
    end

    private def param_decl_text(b : HIR::Binding) : String
      @body.exprs.empty? ? "" : (@param_texts[b.id]? || "")
    end

    @param_texts = {} of HIR::BindingId => String

    # Param texts from the source (splat markers are not in HIR).
    def with_source(text : String) : self
      @body.bindings.each do |b|
        next unless b.kind.param? || b.kind.block_param?
        @param_texts[b.id] = text.byte_slice(b.decl_range.start, b.decl_range.size)
      end
      self
    end

    # -- environment ------------------------------------------------------------

    private def assign(b : HIR::BindingId, ty : TyId) : Nil
      @env[b] = ty
      prev = @binding_types[b]?
      @binding_types[b] = prev ? join(prev, ty) : ty
    end

    private def join(a : TyId, b : TyId) : TyId
      return a if a == b
      u = @table.union([a, b])
      @table.members(u).size > MAX_UNION ? @table.unknown : u
    end

    # Joins branch environments. A binding missing from some branch but not
    # defined before the branches was first assigned in another branch, so
    # it may be Nil afterwards (Crystal semantics).
    private def join_envs(envs : Array(Hash(HIR::BindingId, TyId)), before : Hash(HIR::BindingId, TyId)) : Hash(HIR::BindingId, TyId)
      keys = envs.flat_map(&.keys).uniq
      result = {} of HIR::BindingId => TyId
      keys.each do |k|
        ts = envs.map { |e| e[k]? }
        t = ts.compact.reduce { |a, b| join(a, b) }
        result[k] = ts.any?(&.nil?) && !before.has_key?(k) ? join(t, @table.named!("Nil")) : t
      end
      result
    end

    # -- visitor ---------------------------------------------------------------

    private def visit(id : HIR::ExprId) : TyId
      e = @body.expr(id)
      ty = case e.kind
           when .literal?      then literal(e)
           when .local_ref?    then e.binding.try { |b| @env[b]? } || @table.unknown
           when .self?         then @ctx.self_type
           when .instance_var? then ivar_type(e.name.not_nil!, class_var: false)
           when .class_var?    then ivar_type(e.name.not_nil!, class_var: true)
           when .const?        then const_type(e)
           when .assign?       then visit_assign(e)
           when .multi_assign? then visit_multi_assign(e)
           when .op_assign?    then visit_op_assign(e)
           when .type_decl?    then visit_type_decl(e)
           when .call?         then visit_call(e)
           when .if?, .unless? then visit_if(e)
           when .case?         then visit_case(e)
           when .while?, .until? then visit_loop(e)
           when .seq?          then visit_seq(e)
           when .and?          then visit_and_or(e, and: true)
           when .or?           then visit_and_or(e, and: false)
           when .not?          then e.children.each { |c| visit(c) }; @table.named!("Bool")
           when .collection?   then collection(e)
           when .proc_literal? then visit_proc(e)
           when .block?        then visit_children(e); @table.unknown
           when .begin?        then visit_begin(e)
           when .return?, .break?, .next?
             e.children.each { |c| visit(c) }
             @table.no_return
           when .yield?
             ts = e.children.map { |c| visit(c) }
             ts.each_with_index do |t, i|
               (@yield_types[i]? || (@yield_types << [] of TyId; @yield_types[i])) << t
             end
             @table.unknown
           when .other?
             if e.syntax.uninitialized_var?
               e.type_text.try { |t| parse_type(t) } || @table.unknown
             else
               visit_children(e)
               @table.unknown
             end
           else
             visit_children(e)
             @table.unknown
           end
      @types[id] = ty
      ty
    end

    private def visit_children(e : HIR::Expr) : Nil
      e.receiver.try { |r| visit(r) }
      e.children.each { |c| visit(c) }
      e.named_args.each { |(_, v)| visit(v) }
      e.block.try { |b| visit(b) }
    end

    private def visit_seq(e : HIR::Expr) : TyId
      last = @table.named!("Nil")
      e.children.each { |c| last = visit(c) }
      last
    end

    private def literal(e : HIR::Expr) : TyId
      e.children.each { |c| visit(c) } # interpolations
      case e.syntax
      when .integer?        then int_literal(e.text || "")
      when .float_node?     then (e.text || "").ends_with?("f32") ? @table.named!("Float32") : @table.named!("Float64")
      when .string_node?, .chained_string?, .command?, .heredoc_start? then @table.named!("String")
      when .char_node?      then @table.named!("Char")
      when .symbol_node?    then @table.named!("Symbol")
      when .true_node?, .false_node? then @table.named!("Bool")
      when .nil_node?       then @table.named!("Nil")
      when .regex_node?     then @table.named!("Regex")
      when .pseudo_constant? then @table.unknown
      else                       @table.unknown
      end
    end

    INT_SUFFIXES = %w(i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64)

    private def int_literal(text : String) : TyId
      INT_SUFFIXES.each do |suf|
        if text.ends_with?(suf) && !text.starts_with?("0x")
          name = suf.starts_with?('i') ? "Int#{suf[1..]}" : suf.starts_with?('u') ? "UInt#{suf[1..]}" : "Float#{suf[1..]}"
          return @table.named!(name)
        end
      end
      if text.starts_with?("0x") && (m = text.match(/_?([iu]\d+)\z/))
        suf = m[1]
        return @table.named!(suf.starts_with?('i') ? "Int#{suf[1..]}" : "UInt#{suf[1..]}")
      end
      @table.named!("Int32")
    end

    private def collection(e : HIR::Expr) : TyId
      elems = e.children.map { |c| visit(c) }
      named = e.named_args.map { |(n, v)| {n, visit(v)} }
      case e.syntax
      when .array_node?
        elem = e.type_text.try { |t| parse_type(t) } || (elems.empty? ? @table.unknown : union_or_unknown(elems))
        @table.named!("Array", [elem])
      when .hash_node?
        if k = e.type_text
          @table.named!("Hash", [parse_type(k), e.type_text2.try { |v| parse_type(v) } || @table.unknown])
        else
          keys = elems.each_slice(2).map(&.first).to_a
          vals = elems.each_slice(2).compact_map(&.[1]?).to_a
          @table.named!("Hash", [union_or_unknown(keys), union_or_unknown(vals)])
        end
      when .tuple_node?
        @table.tuple(elems)
      when .named_tuple?
        @table.named_tuple(named.map(&.[0]), named.map(&.[1]))
      when .range_node?
        b = elems[0]? || @table.named!("Nil")
        en = elems[1]? || @table.named!("Nil")
        @table.named!("Range", [b, en])
      when .array_like?, .hash_like?
        # `Set{1, 2}` → Set(Int32)
        name = e.type_text || return @table.unknown
        id = map.lookup_path(name, @ctx.ns) || return @table.unknown
        nparams = map[id].type_params.size
        args = nparams == 1 && !elems.empty? ? [union_or_unknown(elems)] : [] of TyId
        @table.named(id, args)
      else
        @table.unknown
      end
    end

    private def union_or_unknown(ts : Array(TyId)) : TyId
      return @table.unknown if ts.empty?
      u = @table.union(ts)
      @table.members(u).size > MAX_UNION ? @table.unknown : u
    end

    private def const_type(e : HIR::Expr) : TyId
      text = e.name || return @table.unknown
      if id = map.lookup_path(text, @ctx.ns)
        info = map[id]
        if info.kind.alias?
          # Alias to a non-path type (`alias Cb = Int32 -> Nil`).
          if (target = info.sites.first?.try(&.item.detail))
            return @table.metaclass(TypeExprParser.parse(target, @table, info.namespace || Semantics::DefMap::PROGRAM))
          end
        end
        return @table.metaclass(generic_self(id, e))
      end
      # Constant value: `FOO = 1`.
      owner_path, _, name = text.rpartition("::")
      owners = owner_path.empty? ? scope_chain : [map.lookup_path(owner_path, @ctx.ns)].compact
      owners.each do |o|
        map.lookup_member(o, name).each do |site|
          next unless site.item.kind.constant?
          return const_value_type(site, o)
        end
      end
      @table.unknown
    end

    # `Array(Int32)` as an expression: metaclass of the instantiated type.
    private def generic_self(id : Semantics::TypeId, e : HIR::Expr) : TyId
      text = e.name.not_nil!
      return @table.named(id) unless text.includes?('(')
      TypeExprParser.parse(text, @table, @ctx.ns, @ctx.type_params)
    end

    @const_cache = {} of {Int32, String} => TyId

    # Infers a constant's type from its value text by parsing it as a tiny
    # expression: literals and `T.new` only.
    private def const_value_type(site : Semantics::Site, owner : Semantics::TypeId) : TyId
      value = site.item.detail || return @table.unknown
      key = {owner.value, site.item.name}
      @const_cache[key] ||= Infer.value_text_type(value, @table, owner)
    end

    def self.value_text_type(value : String, table : TypeTable, ns : Semantics::TypeId) : TyId
      v = value.strip
      case v
      when /\A-?\d[\d_]*(_?[iu]\d+)?\z/ then table.named!(v =~ /([iu]\d+)\z/ ? ($1.starts_with?('i') ? "Int#{$1[1..]}" : "UInt#{$1[1..]}") : "Int32")
      when /\A-?\d[\d_]*\.\d[\d_]*(_?f32)?\z/ then table.named!(v.ends_with?("f32") ? "Float32" : "Float64")
      when /\A".*"\z/m, /\A%[qQ]?[\(\[\{]/ then table.named!("String")
      when /\A:[\w?!]+\z/, /\A:"/ then table.named!("Symbol")
      when /\A'.+'\z/ then table.named!("Char")
      when "true", "false" then table.named!("Bool")
      when "nil" then table.named!("Nil")
      when /\A\/.*\/[imx]*\z/ then table.named!("Regex")
      when /\A((?:::)?[A-Z][\w:]*(?:\([^)]*\))?)\.new\b/
        TypeExprParser.parse($1, table, ns)
      when /\A\[\] of (.+)\z/ then table.named!("Array", [TypeExprParser.parse($1, table, ns)])
      when /\A\{\} of (.+?) => (.+)\z/ then table.named!("Hash", [TypeExprParser.parse($1, table, ns), TypeExprParser.parse($2, table, ns)])
      else table.unknown
      end
    end

    private def scope_chain : Array(Semantics::TypeId)
      chain = [] of Semantics::TypeId
      cur = @ctx.ns.as(Semantics::TypeId?)
      while c = cur
        chain << c
        cur = map[c].namespace
      end
      chain
    end

    # -- ivars ------------------------------------------------------------------

    @ivar_cache = {} of String => TyId

    # Declared ivar type from the owner and its ancestors: `@x : T`,
    # accessor macros, `def initialize(@x : T)`.
    private def ivar_type(name : String, class_var : Bool) : TyId
      @ivar_cache[name] ||= Infer.ivar_type(map, @table, owner_type_id, name, class_var, @ctx)
    end

    private def owner_type_id : Semantics::TypeId?
      @ctx.ns == Semantics::DefMap::PROGRAM ? nil : @ctx.ns
    end

    def self.ivar_type(map : Semantics::DefMap, table : TypeTable, owner : Semantics::TypeId?, name : String, class_var : Bool, ctx : DefContext) : TyId
      return table.unknown unless owner
      kind = class_var ? Items::ItemKind::ClassVar : Items::ItemKind::InstanceVar
      map.ancestors(owner).each do |anc|
        info = map[anc]
        types = [] of TyId
        if sites = info.members[name]?
          sites.each do |site|
            next unless site.item.kind == kind
            if d = site.item.detail
              t = TypeExprParser.parse(d, table, anc, info.type_params)
              t = value_text_type(d, table, anc) if table.unknown?(t)
              types << t unless table.unknown?(t)
            end
          end
        end
        # `def initialize(@x : T)` params.
        unless class_var
          info.members["initialize"]?.try &.each do |site|
            site.item.signature.try &.params.each do |p|
              next unless p.name == name && (r = p.restriction)
              t = TypeExprParser.parse(r, table, anc, info.type_params)
              types << t unless table.unknown?(t)
            end
          end
        end
        return table.union(types.uniq) unless types.empty?
      end
      table.unknown
    end

    # -- assignment ---------------------------------------------------------------

    private def visit_assign(e : HIR::Expr) : TyId
      target, value = e.children[0]?, e.children[1]?
      ty = value ? visit(value) : @table.unknown
      write_target(target, ty) if target
      ty
    end

    private def visit_multi_assign(e : HIR::Expr) : TyId
      n = e.children.size // 2
      targets = e.children[0, n]
      values = e.children[n..].map { |v| visit(v) }
      if values.size == 1 && targets.size > 1
        # `a, b = tuple`: element types when the value is a tuple.
        t = @table[values[0]]
        targets.each_with_index do |tgt, i|
          elem = t.kind.tuple? ? (t.args[i]? || @table.unknown) : element_type(values[0])
          write_target(tgt, elem)
        end
      else
        targets.each_with_index { |tgt, i| write_target(tgt, values[i]? || @table.unknown) }
      end
      @table.tuple(values)
    end

    private def visit_op_assign(e : HIR::Expr) : TyId
      target, value = e.children[0], e.children[1]
      vt = visit(value)
      tgt = @body.expr(target)
      current = tgt.binding.try { |b| @env[b]? } || @table.unknown
      ty = case e.name
           when "||=" then @table.unknown?(current) ? vt : join(@table.without_nil(current), vt)
           when "&&=" then join(current, vt)
           else
             # `x += 1` → return type of `x.+(1)`.
             op = e.name.try(&.rchop('=')) || "+"
             call_return(current, op, [vt], nil) || current
           end
      write_target(target, ty)
      ty
    end

    private def visit_type_decl(e : HIR::Expr) : TyId
      value = e.children[0]?.try { |c| visit(c) }
      b = e.binding
      declared = b.try { |bid| @body.binding(bid).restriction }.try { |r| parse_type(r) }
      ty = declared || value || @table.unknown
      b.try { |bid| assign(bid, ty) }
      ty
    end

    private def write_target(target : HIR::ExprId, ty : TyId) : Nil
      t = @body.expr(target)
      @types[target] = ty
      if (b = t.binding) && t.kind.local_ref?
        assign(b, ty)
      end
    end

    # -- control flow (structured; CFG arrives in Phase 4) ------------------------

    private def visit_if(e : HIR::Expr) : TyId
      cond, then_b, else_b = e.children[0]?, e.children[1]?, e.children[2]?
      cond.try { |c| visit(c) }
      before = @env.dup
      narrowed = cond ? narrowing(cond, truthy: !e.kind.unless?) : {} of HIR::BindingId => TyId
      @env.merge!(narrowed)
      then_t = then_b ? visit(then_b) : @table.named!("Nil")
      then_env = @env
      @env = before.dup
      else_narrow = cond ? narrowing(cond, truthy: e.kind.unless?) : {} of HIR::BindingId => TyId
      @env.merge!(else_narrow)
      else_t = else_b ? visit(else_b) : @table.named!("Nil")
      else_env = @env
      envs = [] of Hash(HIR::BindingId, TyId)
      envs << then_env unless then_t == @table.no_return
      envs << else_env unless else_t == @table.no_return
      @env = envs.empty? ? before : join_envs(envs, before)
      @table.union([then_t, else_t])
    end

    # Narrowing facts for a condition on simple locals: `x` (truthy → not
    # nil), `x.nil?`, `x.is_a?(T)`, `!cond`, `a && b`.
    private def narrowing(cond : HIR::ExprId, truthy : Bool) : Hash(HIR::BindingId, TyId)
      e = @body.expr(cond)
      result = {} of HIR::BindingId => TyId
      case e.kind
      when .local_ref?
        if (b = e.binding) && (t = @env[b]?) && truthy
          result[b] = @table.without_nil(t)
        end
      when .not?
        e.children[0]?.try { |c| result.merge!(narrowing(c, !truthy)) }
      when .and?
        if truthy
          e.children.each { |c| result.merge!(narrowing(c, true)) }
        end
      when .or?
        unless truthy
          e.children.each { |c| result.merge!(narrowing(c, false)) }
        end
      when .seq?
        e.children.last?.try { |c| result.merge!(narrowing(c, truthy)) }
      when .assign?
        # `if x = foo`: x is truthy in the then-branch.
        if truthy && (tgt = e.children[0]?) && (b = @body.expr(tgt).binding) && (t = @env[b]?)
          result[b] = @table.without_nil(t)
        end
      when .call?
        recv = e.receiver.try { |r| @body.expr(r) }
        b = recv.try(&.binding)
        if recv && recv.kind.local_ref? && b && (t = @env[b]?)
          case e.name
          when "nil?"
            result[b] = truthy ? @table.named!("Nil") : @table.without_nil(t)
          when "is_a?"
            if tt = e.type_text
              target = parse_type(tt)
              result[b] = truthy ? narrow_to(t, target) : exclude(t, target) unless @table.unknown?(target)
            end
          end
        end
      end
      result
    end

    private def narrow_to(current : TyId, target : TyId) : TyId
      return target if @table.unknown?(current)
      kept = @table.members(current).select { |m| subtype?(m, target) }
      kept.empty? ? target : @table.union(kept)
    end

    private def exclude(current : TyId, target : TyId) : TyId
      return current if @table.unknown?(current)
      rest = @table.members(current).reject { |m| subtype?(m, target) }
      rest.empty? ? current : @table.union(rest)
    end

    # Nominal subtyping via DefMap ancestors (generic args ignored).
    def subtype?(a : TyId, b : TyId) : Bool
      return true if a == b
      ta, tb = @table[a], @table[b]
      return @table.members(b).any? { |m| subtype?(a, m) } if tb.kind.union?
      return false unless ta.kind.named? && tb.kind.named?
      return ta.args.empty? || tb.args.empty? || ta.args == tb.args if ta.def_id == tb.def_id
      map.ancestors(ta.def_id.not_nil!).includes?(tb.def_id.not_nil!)
    end

    private def visit_case(e : HIR::Expr) : TyId
      subject = e.children[0]?
      sub_t = subject ? visit(subject) : nil
      before = @env.dup
      branch_types = [] of TyId
      envs = [] of Hash(HIR::BindingId, TyId)
      has_else = false
      e.children[1..]?.try &.each do |c|
        @env = before.dup
        branch = @body.expr(c)
        has_else = true if branch.syntax.else?
        branch_types << visit(c)
        envs << @env
      end
      branch_types << @table.named!("Nil") unless has_else
      envs << before unless has_else
      @env = envs.empty? ? before : join_envs(envs, before)
      @table.union(branch_types)
    end

    private def visit_loop(e : HIR::Expr) : TyId
      before = @env.dup
      # Two passes approximate the loop fixed point for simple cases.
      2.times { e.children.each { |c| visit(c) } }
      @env = join_envs([before, @env], before)
      @table.named!("Nil")
    end

    private def visit_and_or(e : HIR::Expr, and : Bool) : TyId
      ts = [] of TyId
      saved = @env.dup
      e.children.each_with_index do |c, i|
        if and && i > 0
          @env.merge!(narrowing(e.children[i - 1], true))
        end
        ts << visit(c)
      end
      @env = saved.merge(@env) { |_, a, b| join(a, b) }
      if and
        # `a && b`: falsy a, or b.
        first = ts.first? || @table.unknown
        falsy = @table.members(first).select { |m| @table.nil_type?(m) || bool?(m) }
        @table.union(falsy + [ts.last? || @table.unknown])
      else
        @table.union(ts[0...-1].map { |t| @table.without_nil(t) } + [ts.last? || @table.unknown])
      end
    end

    private def bool?(t : TyId) : Bool
      ty = @table[t]
      ty.kind.named? && map[ty.def_id.not_nil!].full_name == "Bool"
    end

    private def visit_begin(e : HIR::Expr) : TyId
      ts = e.children.map { |c| visit(c) }
      ts.first? || @table.unknown
    end

    private def visit_proc(e : HIR::Expr) : TyId
      blk = e.children[0]?.try { |c| @body.expr(c) }
      ret = blk ? visit_block(blk, [] of TyId) : @table.unknown
      @types[e.children[0]] = @table.unknown if blk
      params = blk ? block_args(blk).map { |b| @env[b]? || @table.unknown } : [] of TyId
      @table.proc(params, ret)
    end

    # -- calls --------------------------------------------------------------------

    private def visit_call(e : HIR::Expr) : TyId
      recv_t = e.receiver.try { |r| visit(r) }
      args = e.children.map { |c| visit(c) }
      e.named_args.each { |(_, v)| visit(v) }
      name = e.name || return visit_block_opt(e, [] of TyId) || @table.unknown

      # Built-in pseudo-methods.
      case name
      when "as"
        visit_block_opt(e, [] of TyId)
        return e.type_text.try { |t| parse_type(t) } || @table.unknown
      when "as?"
        return e.type_text.try { |t| @table.nilable(parse_type(t)) } || @table.unknown
      when "is_a?", "nil?", "responds_to?", "==", "!=", "===", "<", ">", "<=", ">=", "!"
        if name.in?("is_a?", "nil?", "responds_to?")
          return @table.named!("Bool")
        end
      when "not_nil!"
        return recv_t ? @table.without_nil(recv_t) : @table.unknown
      when "typeof", "sizeof", "instance_sizeof", "pointerof"
        return name == "pointerof" ? (args[0]?.try { |a| @table.named?("Pointer", [a]) } || @table.unknown) : (name == "typeof" ? @table.unknown : @table.named!("Int32"))
      end

      if name == "try" && recv_t && e.block
        # `x.try { |v| ... }`: v is x without Nil; result is block value or Nil.
        inner = visit_block_opt(e, [@table.without_nil(recv_t)]) || @table.unknown
        return @table.unknown?(inner) ? inner : @table.nilable(inner)
      end

      receiver_type = recv_t || @ctx.self_type
      matches = methods_for(receiver_type, name, args.size, !e.block.nil?)
      block_param_types = block_types_for(matches, receiver_type)
      block_ret = visit_block_opt(e, block_param_types)

      if name == "new" && matches.empty?
        # `Foo.new` without an explicit `self.new`: instance of Foo.
        rt = @table[receiver_type]
        return rt.args[0] if rt.kind.metaclass?
      end

      ret = return_type_for(matches, receiver_type, args, block_ret)
      ret
    end

    private def visit_block_opt(e : HIR::Expr, param_types : Array(TyId)) : TyId?
      blk = e.block.try { |b| @body.expr(b) } || return nil
      visit_block(blk, param_types)
    end

    # Types block args (positionally; a single tuple param type is splatted
    # over several args), visits the body, returns its last expression type.
    private def visit_block(blk : HIR::Expr, param_types : Array(TyId)) : TyId
      args = block_args(blk)
      if param_types.size == 1 && args.size > 1 && @table[param_types[0]].kind.tuple?
        param_types = @table[param_types[0]].args
      end
      args.each_with_index do |b, i|
        r = @body.binding(b).restriction
        t = r ? parse_type(r) : (param_types[i]? || @table.unknown)
        assign(b, t)
      end
      saved_outer = @env.dup
      ret = @table.unknown
      blk.children.each { |c| ret = visit(c) }
      @types[blk.id] = ret
      # Block-local bindings disappear; outer reassignments may or may not
      # have happened: join with the pre-block environment.
      @env = saved_outer.merge(@env.select { |k, _| saved_outer.has_key?(k) }) { |_, a, b| join(a, b) }
      ret
    end

    private def block_args(blk : HIR::Expr) : Array(HIR::BindingId)
      # The block expression lives in its own scope (see LowerBody#lower_block).
      @body.bindings.select { |b| b.scope == blk.scope && b.kind.block_arg? }.map(&.id)
    end

    # Methods named *name* on *receiver_type*: instance methods for instance
    # types, `self.` methods (and `new`/`initialize`) for metaclasses.
    def methods_for(receiver_type : TyId, name : String, nargs : Int32, with_block : Bool) : Array(MethodMatch)
      result = [] of MethodMatch
      @table.members(receiver_type).each do |member|
        t = @table[member]
        case t.kind
        when .named?
          def_id = t.def_id.not_nil!
          bindings = generic_bindings(def_id, t.args)
          map.lookup_member(def_id, name).each do |site|
            next unless site.item.kind.def? || site.item.kind.macro?
            result << MethodMatch.new(site, owner_of(def_id, site), bindings)
          end
        when .metaclass?
          inst = @table[t.args[0]]
          next unless inst.kind.named?
          def_id = inst.def_id.not_nil!
          bindings = generic_bindings(def_id, inst.args)
          sites = map.lookup_member(def_id, "self.#{name}")
          # Methods on the metaclass include module-level `extend self` defs.
          map.extends(def_id).each do |ext|
            sites += map.lookup_member(ext, name)
          end
          sites.each do |site|
            next unless site.item.kind.def? || site.item.kind.macro?
            result << MethodMatch.new(site, owner_of(def_id, site), bindings)
          end
        end
      end
      fitting = result.select { |m| arity_ok?(m.site.item, nargs, with_block) }
      fitting.empty? ? result : fitting
    end

    # The ancestor that declares *site* (for parsing its types).
    private def owner_of(start : Semantics::TypeId, site : Semantics::Site) : Semantics::TypeId
      map.ancestors(start).find { |a| map[a].sites.any? { |s| s.file == site.file && s.item.range.covers?(site.item.range) } } || start
    end

    # Generic params of *def_id* bound to *args* (`Array(T)` + `[String]`
    # → T = String), plus bindings inherited through generic superclasses
    # and includes such as `Indexable(T)`.
    private def generic_bindings(def_id : Semantics::TypeId, args : Array(TyId)) : Hash(String, TyId)
      bindings = {} of String => TyId
      info = map[def_id]
      info.type_params.each_with_index { |p, i| bindings[p] = args[i]? || @table.unknown }
      # Propagate through `include Enumerable(T)` / `< Base(T)` refs.
      refs = info.include_refs.map(&.[0]) + info.superclass_refs.map(&.[0])
      refs.each do |text|
        next unless text.includes?('(')
        pattern = TypeExprParser.parse(text, @table, info.namespace || Semantics::DefMap::PROGRAM, info.type_params)
        pt = @table[pattern]
        next unless pt.kind.named?
        target = map[pt.def_id.not_nil!]
        target.type_params.each_with_index do |tp, i|
          next if bindings.has_key?(tp)
          if a = pt.args[i]?
            bindings[tp] = Subst.apply(@table, a, bindings)
          end
        end
      end
      bindings
    end

    # Positional arity check. Blocks and named args are not checked yet
    # (Phase 5 does full argument binding).
    private def arity_ok?(item : Items::Item, nargs : Int32, with_block : Bool) : Bool
      sig = item.signature || return true
      # A def whose body yields needs a block; `&` / `&block` marks it. The
      # common `first(&)` vs `first : T` overload pairs need this to pick
      # the right one.
      block = sig.params.find(&.kind.block?)
      return false if block && !with_block && block.name.nil?
      positional = sig.params.select(&.kind.positional?)
      splat = sig.params.any? { |p| p.kind.splat? && p.name }
      required = positional.count { |p| p.default.nil? && !named_only?(sig, p) }
      max = splat ? Int32::MAX : positional.count { |p| !named_only?(sig, p) }
      nargs >= required && nargs <= max
    end

    private def named_only?(sig : Items::Signature, p : Items::Param) : Bool
      idx = sig.params.index(p) || return false
      sig.params[0...idx].any?(&.kind.splat?)
    end

    # Block arg types from `& : T, U -> R` / `&block : T -> R` restrictions,
    # else from the `yield`s in the method body (shallow summary).
    private def block_types_for(matches : Array(MethodMatch), receiver_type : TyId) : Array(TyId)
      matches.each do |m|
        sig = m.site.item.signature || next
        bp = sig.params.find(&.kind.block?)
        r = bp.try(&.restriction)
        unless r
          ts = yield_summary(m, receiver_type)
          return ts unless ts.empty?
          next
        end
        owner = map[m.owner]
        t = TypeExprParser.parse(r, @table, m.owner, owner.type_params + sig.free_vars, self_for(receiver_type))
        pt = @table[t]
        next unless pt.kind.proc?
        return pt.args[0...-1].map { |a| Subst.apply(@table, a, m.bindings) }
      end
      [] of TyId
    end

    private def return_type_for(matches : Array(MethodMatch), receiver_type : TyId, args : Array(TyId), block_ret : TyId?) : TyId
      results = [] of TyId
      matches.each do |m|
        t = declared_return(m, receiver_type, args, block_ret) || next
        results << t
      end
      return @table.unknown if results.empty? || results.size != matches.size && matches.size > 1
      union_or_unknown(results.uniq)
    end

    # Return type of one candidate, with generic and `forall` substitution.
    private def declared_return(m : MethodMatch, receiver_type : TyId, args : Array(TyId), block_ret : TyId?) : TyId?
      item = m.site.item
      sig = item.signature || return nil
      owner = map[m.owner]
      self_t = self_for(receiver_type)
      text = sig.return_type
      if text.nil?
        # `def initialize` via `self.new` and accessor macros without types.
        return nil unless item.name == "new"
        return self_t
      end
      tparams = owner.type_params + sig.free_vars
      ret = TypeExprParser.parse(text, @table, m.owner, tparams, self_t)
      bindings = m.bindings.dup
      unless sig.free_vars.empty?
        # Bind free vars from argument restrictions and the block.
        positional = sig.params.select(&.kind.positional?)
        positional.each_with_index do |p, i|
          next unless (r = p.restriction) && (a = args[i]?)
          Subst.unify(@table, TypeExprParser.parse(r, @table, m.owner, tparams, self_t), a, bindings)
        end
        if (bp = sig.params.find(&.kind.block?)) && (r = bp.restriction) && block_ret
          pt = TypeExprParser.parse(r, @table, m.owner, tparams, self_t)
          if @table[pt].kind.proc?
            Subst.unify(@table, @table[pt].args.last, block_ret, bindings)
          end
        end
      end
      result = Subst.apply(@table, ret, bindings)
      Subst.open?(@table, result) ? nil : result
    end

    # `self` in a method's signature: the receiver instance type.
    private def self_for(receiver_type : TyId) : TyId
      t = @table[receiver_type]
      t.kind.metaclass? ? t.args[0] : receiver_type
    end

    @yield_cache = {} of {Int32, Int32, UInt32, Int32} => Array(TyId)

    # Infers a candidate's body once (depth-limited) and returns the joined
    # types of each `yield` argument, with the receiver's generic bindings.
    private def yield_summary(m : MethodMatch, receiver_type : TyId) : Array(TyId)
      return [] of TyId if summary_depth <= 0
      loader = @source_loader || return [] of TyId
      key = {m.site.file.value.to_i32, m.owner.value, m.site.item.range.start, receiver_type.value}
      @yield_cache[key] ||= begin
        node = loader.call(m.site)
        if node
          owner = map[m.owner]
          self_t = self_for(receiver_type)
          ctx = DefContext.new(m.owner, self_t, owner.type_params + (m.site.item.signature.try(&.free_vars) || [] of String))
          inner = Infer.new(HIR::LowerBody.lower(node), ctx, @table)
          inner.source_loader = loader
          inner.summary_depth = summary_depth - 1
          inner.with_source(node.tree.text).run
          inner.yield_types.map do |ts|
            joined = union_or_unknown(ts.uniq)
            r = Subst.apply(@table, joined, m.bindings)
            Subst.open?(@table, r) ? @table.unknown : r
          end
        else
          [] of TyId
        end
      end
    end

    # Return type of `recv.name(args)` (used by op-assign).
    private def call_return(recv : TyId, name : String, args : Array(TyId), block_ret : TyId?) : TyId?
      return nil if @table.unknown?(recv)
      matches = methods_for(recv, name, args.size, false)
      t = return_type_for(matches, recv, args, block_ret)
      @table.unknown?(t) ? nil : t
    end

    private def element_type(t : TyId) : TyId
      ty = @table[t]
      ty.kind.named? && ty.args.size == 1 ? ty.args[0] : @table.unknown
    end

    private def parse_type(text : String) : TyId
      TypeExprParser.parse(text, @table, @ctx.ns, @ctx.type_params, @ctx.self_type)
    end
  end
end
