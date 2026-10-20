require "../hir"
require "../flow"
require "../workspace/index"
require "./type_expr"

module ClearLS::Types
  # Where a def lives, for return-type parsing and `self`.
  record DefContext, ns : Semantics::TypeId, self_type : TyId, type_params : Array(String)

  # Candidate methods for a call on a receiver type.
  record MethodMatch, site : Semantics::Site, owner : Semantics::TypeId, bindings : Hash(String, TyId)

  # Flow-sensitive local type inference over one body.
  #
  # Forward dataflow on the body's `Flow::CFG`: the state is an environment
  # `HIR::BindingId → TyId` per block entry, solved with a worklist in
  # reverse postorder. Joins union the incoming types; a binding missing on
  # one incoming path was not yet assigned there and becomes nilable
  # (Crystal semantics). Branch edges refine locals (truthiness, `nil?`,
  # `is_a?`); an edge whose refinement leaves a local with no possible type
  # is infeasible. Expressions of type NoReturn (a `raise`, a call declared
  # `: NoReturn`, an `if` whose branches all return) end the reachable part
  # of their block.
  #
  # Unreachable code (after `return`, ...) is analysed afterwards in a
  # separate pass, starting from the state of the code it follows, so
  # editing it still gets completion; it never flows into reachable code.
  #
  # Block args are typed from the called method's block restriction or
  # yield summary when the closure body is entered.
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
    # Times a block's entry state may change before changed bindings widen
    # to unknown.
    MAX_VISITS = 8

    alias Env = Hash(HIR::BindingId, TyId)

    # Loads a def's source (body lowering for yield summaries). Provided by
    # the caller; returns nil when the file cannot be read.
    alias SourceLoader = Proc(Semantics::Site, Syntax::Node?)
    property source_loader : SourceLoader? = nil
    # Remaining depth for nested summaries (yield types of called methods).
    property summary_depth = 1

    @env = {} of HIR::BindingId => TyId

    getter! cfg : Flow::CFG
    # Block entry states: reachable blocks, then unreachable ones (second pass).
    @in = {} of Int32 => Env
    # State at each analysed block's end, also when its end is unreachable
    # (rescue dispatch and dead code start from it).
    @end_env = {} of Int32 => Env
    # Blocks whose end is reachable.
    @live_out = Set(Int32).new
    @visits = Hash(Int32, Int32).new(0)
    @pending = [] of Bool
    @rank = [] of Int32
    @by_rank = [] of Int32
    @main_pass = true
    # Consumer of each expression's value (`HIR` parent).
    @parent = {} of HIR::ExprId => HIR::ExprId

    def initialize(@body : HIR::Body, @ctx : DefContext, @table : TypeTable)
      @types = {} of HIR::ExprId => TyId
      @binding_types = {} of HIR::BindingId => TyId
    end

    def map : Semantics::DefMap
      @table.def_map
    end

    def run : self
      @cfg = Flow::Builder.build(@body)
      @body.exprs.each do |e|
        e.receiver.try { |r| @parent[r] = e.id }
        e.children.each { |c| @parent[c] = e.id }
        e.named_args.each { |(_, v)| @parent[v] = e.id }
        e.block.try { |b| @parent[b] = e.id }
      end
      seed_params
      solve(@env.dup)
      @main_pass = false
      @reached = @in.keys.to_set
      solve_dead
      self
    end

    # Entry state of a reachable or analysed-unreachable block.
    def block_entry(b : Flow::BlockId) : Env?
      @in[b.value]?
    end

    # Was the block reached by the main (reachable-code) analysis?
    def reachable?(b : Flow::BlockId) : Bool
      @reached.includes?(b.value)
    end

    @reachable_count = 0
    @reached = Set(Int32).new

    def type_of(id : HIR::ExprId) : TyId
      @types[id]? || @table.unknown
    end

    # Join of every type assigned to *b* in this body.
    def binding_type(b : HIR::BindingId) : TyId
      @binding_types[b]? || @table.unknown
    end

    # -- program points -----------------------------------------------------------

    # Environment right before *id* is evaluated (`ProgramPoint` Before),
    # by replaying its block from the block's entry state. Expressions
    # without an operation of their own (assignment targets) use the
    # operation of their parent: in `x = foo` the target sees the state
    # before the assignment.
    def env_before(id : HIR::ExprId) : Env?
      op_expr = id.as(HIR::ExprId?)
      while (x = op_expr) && !cfg.eval_block.has_key?(x)
        op_expr = @parent[x]?
      end
      target = op_expr || return nil
      blk = cfg[cfg.eval_block[target]]
      entry = @in[blk.id.value]? || return nil
      replay(blk, entry) { |op| op.kind.eval? && op.expr == target }
    end

    # Environment at a cursor *offset*: before the smallest expression
    # covering it. Between statements this is the state after the
    # preceding statement.
    def env_at(offset : UInt32) : Env?
      if e = @body.expr_at(offset)
        unless e.kind.seq? || e.kind.nop? || e.kind.missing?
          return env_before(e.id)
        end
      end
      # Whitespace: after the last operation that ends at or before offset.
      best = nil.as({Flow::Block, Int32}?)
      best_end = 0_u32
      cfg.blocks.each do |b|
        next unless @in.has_key?(b.id.value)
        b.ops.each_with_index do |op, i|
          r = @body.expr(op.expr).range
          next unless r.end <= offset && r.end >= best_end
          next if @body.expr(op.expr).kind.seq?
          best, best_end = {b, i}, r.end
        end
      end
      bb, idx = best || return nil
      entry = @in[bb.id.value]
      count = -1
      replay(bb, entry) { (count += 1) > idx }
    end

    # Type of *b* at *offset*, or nil when not known there.
    def binding_type_at(b : HIR::BindingId, offset : UInt32) : TyId?
      env_at(offset).try(&.[b]?)
    end

    @replaying = false

    private def replay(blk : Flow::Block, entry : Env, & : Flow::Op -> Bool) : Env
      saved_env = @env
      @replaying = true
      @env = entry.dup
      blk.ops.each do |op|
        break if yield op
        op.kind.enter? ? enter(op.expr) : eval_expr(op.expr)
      end
      @env
    ensure
      @env = saved_env.not_nil!
      @replaying = false
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

    # Joins two incoming states. A binding missing on one side was not
    # assigned on that path yet: it may be Nil.
    private def join_env(a : Env, b : Env) : Env
      return a if a == b
      result = {} of HIR::BindingId => TyId
      a.each do |k, t|
        result[k] = (o = b[k]?) ? join(t, o) : join(t, nil_t)
      end
      b.each do |k, t|
        result[k] = join(t, nil_t) unless a.has_key?(k)
      end
      result
    end

    private def nil_t : TyId
      @table.named!("Nil")
    end

    # -- dataflow -----------------------------------------------------------------

    # Reverse postorder over normal and exception edges; unreachable blocks
    # follow in id order (roughly lexical).
    private def compute_order : Nil
      n = cfg.blocks.size
      @rank = Array(Int32).new(n, -1)
      post = [] of Int32
      seen = Array(Bool).new(n, false)
      # Iterative DFS: {block, next successor index}.
      stack = [{0, 0}]
      seen[0] = true
      while top = stack.last?
        b, i = top
        blk = cfg.blocks[b]
        succs = blk.succs
        nexts = blk.handler ? succs + [blk.handler.not_nil!] : succs
        if i < nexts.size
          stack[-1] = {b, i + 1}
          s = nexts[i].value
          unless seen[s]
            seen[s] = true
            stack << {s, 0}
          end
        else
          post << b
          stack.pop
        end
      end
      @by_rank = post.reverse
      @reachable_count = @by_rank.size
      n.times { |b| @by_rank << b unless seen[b] }
      @by_rank.each_with_index { |b, r| @rank[b] = r }
      @pending = Array(Bool).new(n, false)
    end

    private def solve(entry : Env) : Nil
      compute_order
      @in[0] = entry
      @pending[0] = true
      while r = @pending.index(true)
        @pending[r] = false
        b = cfg.blocks[@by_rank[r]]
        alive = transfer(b, @in[b.id.value])
        propagate(b, alive)
      end
    end

    private def enqueue(b : Int32) : Nil
      @pending[@rank[b]] = true
    end

    # Runs a block's operations from *env*. Returns whether its end is
    # reachable.
    private def transfer(b : Flow::Block, env : Env) : Bool
      @env = env.dup
      alive = true
      b.ops.each do |op|
        if op.kind.enter?
          enter(op.expr)
          next
        end
        prev = @types[op.expr]?
        t = eval_expr(op.expr)
        if t == @table.no_return && alive
          k = @body.expr(op.expr).kind
          alive = false unless k.local_ref? || k.return? || k.break? || k.next?
        end
        notify_consumer(op.expr, b.id) if @main_pass && prev && prev != t
      end
      @end_env[b.id.value] = @env
      @live_out << b.id.value if alive && @main_pass
      alive
    end

    # A value read by an expression in another block changed (a closure's
    # value, a branch value of an `if`): reanalyse that block.
    private def notify_consumer(id : HIR::ExprId, from : Flow::BlockId) : Nil
      cur = @parent[id]?
      while c = cur
        if blk = cfg.eval_block[c]?
          enqueue(blk.value) if blk != from && @in.has_key?(blk.value)
          return
        end
        cur = @parent[c]?
      end
    end

    private def propagate(b : Flow::Block, alive : Bool) : Nil
      out_env = @end_env[b.id.value]
      if alive
        b.succs.each_with_index do |s, i|
          env = refine(out_env, b, i) || next
          merge_into(s.value, env)
        end
      end
      if h = b.handler
        # An exception may occur anywhere in the block.
        merge_into(h.value, join_env(@in[b.id.value], out_env))
      end
    end

    private def merge_into(s : Int32, env : Env) : Nil
      old = @in[s]?
      new = old ? join_env(old, env) : env
      return if old == new
      @visits[s] += 1
      if old && @visits[s] > MAX_VISITS
        new = new.to_h { |k, t| {k, old[k]? == t ? t : @table.unknown} }
        return if old == new
      end
      @in[s] = new
      enqueue(s)
    end

    # State along successor *i* of *b* (0 = true edge of a branch), or nil
    # when the edge is infeasible.
    private def refine(env : Env, b : Flow::Block, i : Int32) : Env?
      return env unless b.terminator == Flow::Terminator::Branch
      test = b.test || return env
      @env = env
      facts = edge_facts(test, i == 0)
      return env if facts.empty?
      refined = env.dup
      facts.each do |k, t|
        return nil if t == @table.no_return
        refined[k] = t
      end
      refined
    end

    private def edge_facts(test : Flow::Test, truthy : Bool) : Env
      case test.kind
      in .truthy?    then narrowing(test.cond, truthy)
      in .case_when? then case_facts(test.cond, test.subject.not_nil!, truthy)
      end
    end

    # `case x` / `when T`, `when nil`, `when .nil?`, `when .is_a?(T)`, and
    # `in T`: refines the subject local. Value conditions (`when 1`) only
    # narrow on a match, to the value's type.
    private def case_facts(cond : HIR::ExprId, subject : HIR::ExprId, truthy : Bool) : Env
      result = {} of HIR::BindingId => TyId
      s = @body.expr(subject)
      return result unless s.kind.local_ref?
      b = s.binding || return result
      t = @env[b]? || return result
      c = @body.expr(cond)
      target = case c.kind
               when .const?
                 ct = @table[operand(cond)]
                 ct.kind.metaclass? ? ct.args[0] : nil
               when .literal?
                 lt = operand(cond)
                 if c.syntax.nil_node?
                   lt
                 else
                   # `when 1`: a match means x == 1 (Int32); no fact otherwise.
                   result[b] = narrow_to(t, lt) if truthy && !@table.unknown?(lt) && !c.syntax.regex_node?
                   return result
                 end
               when .call?
                 if c.receiver.nil? && c.syntax.implicit_object_call?
                   case c.name
                   when "nil?" then nil_t
                   when "is_a?" then c.type_text.try { |tt| parse_type(tt) }
                   end
                 end
               end
      return result if target.nil? || @table.unknown?(target)
      result[b] = truthy ? narrow_to(t, target) : exclude(t, target)
      result
    end

    # Blocks the main pass never reached (after jumps, behind infeasible
    # edges), in rank order: start from analysed predecessors, else from the
    # block they follow lexically, else from the rescued blocks, else empty.
    private def solve_dead : Nil
      @by_rank.each do |bi|
        next if @in.has_key?(bi)
        b = cfg.blocks[bi]
        env = nil.as(Env?)
        b.preds.each do |p|
          e = @end_env[p.value]? || next
          e = refine(e, cfg[p], cfg[p].succs.index!(b.id)) || e
          env = env ? join_env(env, e) : e
        end
        if env.nil? && (f = b.fallback)
          env = @end_env[f.value]?
        end
        if env.nil?
          b.exc_preds.each do |p|
            e = @end_env[p.value]? || next
            env = env ? join_env(env, e) : e
          end
        end
        env ||= {} of HIR::BindingId => TyId
        @in[bi] = env
        transfer(b, env)
      end
    end

    # Value of a join expression from its reachable sources.
    private def merge_type(id : HIR::ExprId) : TyId
      srcs = cfg.merges[id]? || return @table.unknown
      live = srcs.select { |s| @live_out.includes?(s.block.value) }
      live = srcs.select { |s| @end_env.has_key?(s.block.value) } if live.empty? && !@main_pass
      ts = live.compact_map { |s| source_type(s) }
      @table.union(ts)
    end

    private def source_type(s : Flow::Source) : TyId?
      t = s.expr.try { |x| operand(x) } || nil_t
      case s.filter
      in .none?   then t
      in .truthy? then @table.without_nil(t)
      in .falsy?
        return t if @table.unknown?(t)
        falsy = @table.members(t).select { |m| @table.nil_type?(m) || bool?(m) }
        falsy.empty? ? nil : @table.union(falsy)
      end
    end

    # Type computed by an earlier operation.
    private def operand(id : HIR::ExprId) : TyId
      @types[id]? || @table.unknown
    end

    # -- visitor ---------------------------------------------------------------

    # Transfer function of one `Eval` operation; operands were evaluated by
    # earlier operations.
    private def eval_expr(id : HIR::ExprId) : TyId
      e = @body.expr(id)
      ty = case e.kind
           when .literal?      then literal(e)
           when .nop?          then @table.named!("Nil")
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
           when .if?, .unless?, .case?, .begin?, .and?, .or?
             merge_type(id)
           when .while?, .until? then nil_t
           when .seq?          then e.children.last?.try { |c| operand(c) } || nil_t
           when .not?          then @table.named!("Bool")
           when .collection?   then collection(e)
           when .proc_literal? then eval_proc(e)
           when .block?        then merge_type(id)
           when .return?, .break?, .next?
             @table.no_return
           when .yield?
             ts = e.children.map { |c| operand(c) }
             ts = [] of TyId if @replaying
             ts.each_with_index do |t, i|
               (@yield_types[i]? || (@yield_types << [] of TyId; @yield_types[i])) << t
             end
             @table.unknown
           when .other?
             if e.syntax.uninitialized_var?
               e.type_text.try { |t| parse_type(t) } || @table.unknown
             else
               @table.unknown
             end
           else
             @table.unknown
           end
      @types[id] = ty
      ty
    end

    private def literal(e : HIR::Expr) : TyId
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
      elems = e.children.map { |c| operand(c) }
      named = e.named_args.map { |(n, v)| {n, operand(v)} }
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
      ty = value ? operand(value) : @table.unknown
      write_target(target, ty) if target
      ty
    end

    private def visit_multi_assign(e : HIR::Expr) : TyId
      n = e.children.size // 2
      targets = e.children[0, n]
      values = e.children[n..].map { |v| operand(v) }
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
      vt = operand(value)
      tgt = @body.expr(target)
      # Locals from the environment; `@x ||= v` from the evaluated target.
      current = tgt.kind.local_ref? ? (tgt.binding.try { |b| @env[b]? } || @table.unknown) : operand(target)
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
      value = e.children[0]?.try { |c| operand(c) }
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

    # -- narrowing ----------------------------------------------------------------

    # Narrowing facts for a condition on simple locals: `x` (truthy → not
    # nil, falsy → its Nil/Bool part), `x.nil?`, `x.is_a?(T)`, `!cond`,
    # `a && b`, `a || b`, `x = v`. Reads `@env` (the state at the end of the
    # condition's block).
    private def narrowing(cond : HIR::ExprId, truthy : Bool) : Hash(HIR::BindingId, TyId)
      e = @body.expr(cond)
      result = {} of HIR::BindingId => TyId
      case e.kind
      when .local_ref?
        if (b = e.binding) && (t = @env[b]?) && !@table.unknown?(t)
          if truthy
            result[b] = @table.without_nil(t)
          else
            falsy = @table.members(t).select { |m| @table.nil_type?(m) || bool?(m) }
            result[b] = @table.union(falsy) unless falsy.empty?
          end
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
        if truthy && (tgt = e.children[0]?) && (b = @body.expr(tgt).binding) && (t = @env[b]?) && !@table.unknown?(t)
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

    private def bool?(t : TyId) : Bool
      ty = @table[t]
      ty.kind.named? && map[ty.def_id.not_nil!].full_name == "Bool"
    end

    private def eval_proc(e : HIR::Expr) : TyId
      blk = e.children[0]?.try { |c| @body.expr(c) } || return @table.unknown
      ret = @types[blk.id]? || @table.unknown
      params = block_args(blk).map { |b| @body.binding(b).restriction.try { |r| parse_type(r) } || @table.unknown }
      @table.proc(params, ret)
    end

    # Entering a closure body (block params) or a rescue clause.
    private def enter(id : HIR::ExprId) : Nil
      e = @body.expr(id)
      if e.kind.rescue?
        e.binding.try { |b| assign(b, e.type_text.try { |t| parse_type(t) } || @table.named!("Exception")) }
        return
      end
      own = own_scope?(e)
      if own
        # Locals first assigned inside the block are fresh per iteration.
        @env.reject! { |k, _| k_in_scope?(k, e.scope) }
      end
      owner = cfg.closure_owner[id]?.try { |o| @body.expr(o) }
      param_types = owner && owner.kind.call? ? closure_param_types(owner) : [] of TyId
      args = block_args(e)
      if param_types.size == 1 && args.size > 1 && @table[param_types[0]].kind.tuple?
        param_types = @table[param_types[0]].args
      end
      args.each_with_index do |b, i|
        r = @body.binding(b).restriction
        assign(b, r ? parse_type(r) : (param_types[i]? || @table.unknown))
      end
    end

    private def k_in_scope?(b : HIR::BindingId, scope : HIR::ScopeId) : Bool
      sid = @body.binding(b).scope.as(HIR::ScopeId?)
      while s = sid
        return true if s == scope
        sid = @body.scope(s).parent
      end
      false
    end

    # Blocks from `do |x| ... end` / `{ ... }` / proc literals open a scope
    # covering exactly the block; `&.foo` / `&block` arguments do not.
    private def own_scope?(blk : HIR::Expr) : Bool
      blk.scope.value != 0 && @body.scope(blk.scope).range == blk.range && @body.scope(blk.scope).kind.block?
    end

    # Block arg types for a call's block.
    private def closure_param_types(call : HIR::Expr) : Array(TyId)
      name = call.name || return [] of TyId
      recv_t = call.receiver.try { |r| operand(r) }
      return [] of TyId if name.in?("as", "as?")
      return [@table.without_nil(recv_t)] if name == "try" && recv_t
      receiver_type = recv_t || @ctx.self_type
      matches = methods_for(receiver_type, name, call.children.size, true)
      block_types_for(matches, receiver_type)
    end

    # -- calls --------------------------------------------------------------------

    private def visit_call(e : HIR::Expr) : TyId
      recv_t = e.receiver.try { |r| operand(r) }
      args = e.children.map { |c| operand(c) }
      block_ret = e.block.try { |b| @types[b]? }
      name = e.name || return block_ret || @table.unknown

      # Built-in pseudo-methods.
      case name
      when "as"
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
        inner = block_ret || @table.unknown
        return @table.unknown?(inner) ? inner : @table.nilable(inner)
      end

      receiver_type = recv_t || @ctx.self_type
      matches = methods_for(receiver_type, name, args.size, !e.block.nil?)
      matches = top_level_methods(name, args.size, !e.block.nil?) if matches.empty? && recv_t.nil?

      if name == "new" && matches.empty?
        # `Foo.new` without an explicit `self.new`: instance of Foo.
        rt = @table[receiver_type]
        return rt.args[0] if rt.kind.metaclass?
      end

      ret = return_type_for(matches, receiver_type, args, block_ret)
      ret
    end

    private def block_args(blk : HIR::Expr) : Array(HIR::BindingId)
      # The block expression lives in its own scope (see LowerBody#lower_block).
      return [] of HIR::BindingId unless own_scope?(blk)
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

    # Receiverless calls not found on `self`: top-level defs (`raise`,
    # `puts`).
    def top_level_methods(name : String, nargs : Int32, with_block : Bool) : Array(MethodMatch)
      sites = map.program.members[name]? || return [] of MethodMatch
      all = sites.select { |s| s.item.kind.def? || s.item.kind.macro? }
        .map { |s| MethodMatch.new(s, Semantics::DefMap::PROGRAM, {} of String => TyId) }
      fitting = all.select { |m| arity_ok?(m.site.item, nargs, with_block) }
      fitting.empty? ? all : fitting
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
