require "../hir"
require "../flow"
require "../workspace/index"
require "./type_expr"
require "./call_resolver"
require "./summaries"

module ClearLS::Types
  # Where a def lives, for return-type parsing and `self`.
  record DefContext, ns : Semantics::TypeId, self_type : TyId, type_params : Array(String)


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
    # Join of the `with x yield` receivers in this body.
    getter with_self : TyId? = nil

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
    # Shared summary cache (one per Typing). Without one, unannotated
    # returns stay unknown.
    property summaries : Summaries? = nil
    # Types for unrestricted params by index in the def's signature, from
    # the call being summarised.
    property param_args = [] of TyId
    # Type of `yield` in this body: the caller's block value (summaries
    # for one call site), else unknown.
    property yield_value : TyId? = nil
    # Inferring a def for a summary (not a body the user is editing).
    property summarising = false

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
      find_captured
      start = @env.dup
      solve(start)
      unless @captured.empty?
        # Captured locals: re-solve with the joins of the first pass as
        # their type everywhere (assignments seen later now count before).
        @captured.each { |b| (t = @binding_types[b]?) && (@captured_types[b] = t) }
        reset_solution
        solve(start.dup)
      end
      @main_pass = false
      @reached = @in.keys.to_set
      solve_dead
      final_binding_types
      self
    end

    # Clears per-solve state for a second solve of the same body (types
    # and resolutions are overwritten by it).
    private def reset_solution : Nil
      @in.clear
      @end_env.clear
      @live_out.clear
      @visits.clear
      @reentries.clear
      @jump_values.clear
      @yield_types.clear
      @with_self = nil
      seeded = @binding_types.select { |b, _| k = @body.binding(b).kind; k.param? || k.block_param? }
      @binding_types = seeded
    end

    # Locals of this body used inside a proc literal or a captured block
    # (closures.md): their type is the join of every assignment anywhere,
    # and they are never narrowed (the closure may run at any time).
    @captured = Set(HIR::BindingId).new
    # Join of all assignments so far, per captured local.
    @captured_types = {} of HIR::BindingId => TyId

    private def find_captured : Nil
      @body.exprs.each do |e|
        next unless e.kind.block?
        owner = cfg.closure_owner[e.id]?.try { |o| @body.expr(o) } || next
        next unless owner.kind.proc_literal? || capturing_call?(owner)
        own = e.scope
        @body.exprs.each do |x|
          next unless x.kind.local_ref? && e.range.covers?(x.range)
          b = x.binding || next
          @captured << b unless k_in_scope?(b, own)
        end
      end
    end

    # A call whose block parameter is captured (`def f(&block)` without
    # `yield`): every candidate stores the block rather than yielding.
    private def capturing_call?(call : HIR::Expr) : Bool
      return false unless call.kind.call? && call.block
      name = call.name || return false
      # Cheap pre-check: some def with this name has a named `&block`
      # param (most block calls go to methods that yield).
      return false unless capturing_name?(name)
      cands = resolve_call(call).candidates
      !cands.empty? && cands.all? do |c|
        sig = c.match.site.item.signature || next false
        bp = sig.params.find(&.kind.block?) || next false
        !bp.name.nil? && !yields?(c.match.site)
      end
    end

    # Names of defs anywhere that take a named block param (`&block`),
    # per DefMap (shared by every Infer of one Typing).
    @@capturing_names = {} of UInt64 => Set(String)

    private def capturing_name?(name : String) : Bool
      names = @@capturing_names[map.object_id] ||= begin
        @@capturing_names.clear
        set = Set(String).new
        map.types.each do |info|
          info.members.each do |key, sites|
            sites.each do |site|
              sig = site.item.signature || next
              if sig.params.any? { |p| p.kind.block? && !p.name.nil? }
                set << key.lchop("self.")
                break
              end
            end
          end
        end
        set
      end
      names.includes?(name)
    end

    @yields_cache = {} of {Int32, UInt32} => Bool

    private def yields?(site : Semantics::Site) : Bool
      @yields_cache[{site.file.value.to_i32, site.item.range.start}] ||= begin
        node = @source_loader.try(&.call(site))
        node ? node.tree.text.byte_slice(node.start_byte, node.end_byte - node.start_byte).matches?(/\byield\b/) : true
      end
    end

    # Joins of every value assigned to each binding, taken from one final
    # replay of each analysed block, so values from earlier (not yet
    # converged) worklist iterations do not leak in.
    private def final_binding_types : Nil
      seeded = @binding_types.select { |b, _| k = @body.binding(b).kind; k.param? || k.block_param? }
      @binding_types = seeded
      @collecting = true
      cfg.blocks.each do |b|
        entry = @in[b.id.value]? || next
        replay(b, entry) { false }
      end
    ensure
      @collecting = false
    end

    @collecting = false

    # Tuple values of `return a, b` (the jump itself has type NoReturn).
    @jump_values = {} of HIR::ExprId => TyId

    private def source_value(x : HIR::ExprId) : TyId
      k = @body.expr(x).kind
      (k.return? || k.break? || k.next?) ? (@jump_values[x]? || nil_t) : operand(x)
    end

    # Joined type of every value the body returns (unknown when any path's
    # value is unknown); NoReturn when no path returns.
    MACRO_KINDS = {Syntax::Kind::MacroIf, Syntax::Kind::MacroUnless, Syntax::Kind::MacroFor,
                   Syntax::Kind::MacroExpression, Syntax::Kind::MacroStatement,
                   Syntax::Kind::MacroVerbatim, Syntax::Kind::MacroBegin}

    # Does the body contain macro code (`{% for %}`, `{{ }}`) that lowering
    # keeps opaque and that returns? A summary of the remaining code would
    # miss those values (`Range#bsearch` returns from a `{% for %}`).
    def opaque_macros? : Bool
      src = @source || return false
      # `{% if flag?(...) %}` / `{% unless %}` blocks: the value returned
      # inside is a platform variant of the code around it; summarising
      # without it is a best effort. Loops and expansions generate code.
      @body.exprs.any? do |x|
        x.kind.missing? && x.syntax.in?(MACRO_KINDS) && !x.syntax.macro_if? && !x.syntax.macro_unless? &&
          src.byte_slice(x.range.start, x.range.size).matches?(/\breturn\b/)
      end
    end

    def return_type : TyId
      srcs = cfg.returns.select { |s| @live_out.includes?(s.block.value) }
      return @table.no_return if srcs.empty?
      ts = srcs.map { |s| s.expr.try { |x| source_value(x) } || nil_t }
      union_or_unknown(ts.uniq)
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
      index = -1
      @body.bindings.each do |b|
        next unless b.kind.param? || b.kind.block_param?
        index += 1
        given = @param_args[index]?
        ty = if given && !@table.unknown?(given)
               given
             elsif r = b.restriction
               parse_type(r)
             else
               @table.unknown
             end
        # Splats: the call's tuple / named tuple when summarised for a
        # call; otherwise unknown sizes (`Tuple`, `NamedTuple`).
        decl = param_decl_text(b)
        given_known = given && !@table.unknown?(given)
        if decl.starts_with?("**")
          ty = given_known ? given.not_nil! : (@table.named?("NamedTuple") || @table.unknown)
        elsif decl.starts_with?('*')
          ty = given_known ? given.not_nil! : (@table.named?("Tuple") || @table.unknown)
        elsif b.kind.block_param?
          ty = block_param_type(r, ty)
        end
        assign(b.id, ty)
      end
    end

    # `&block`: a `Proc(Nil)` (the block takes no args; its value is
    # dropped); `&block : T -> _` returns the caller's block value, which
    # summaries know (`yield_value`).
    private def block_param_type(restriction : String?, declared : TyId) : TyId
      unless restriction
        return @table.proc([] of TyId, nil_t)
      end
      pt = @table[declared]
      if pt.kind.proc? && @table.unknown?(pt.args.last) && restriction.rstrip.ends_with?('_')
        if (v = @yield_value) && !@table.unknown?(v)
          return @table.proc(pt.args[0...-1], v)
        end
      end
      declared
    end

    private def param_decl_text(b : HIR::Binding) : String
      @body.exprs.empty? ? "" : (@param_texts[b.id]? || "")
    end

    @param_texts = {} of HIR::BindingId => String

    # Param texts from the source (splat markers are not in HIR).
    @source : String? = nil

    def with_source(text : String) : self
      @source = text
      @body.bindings.each do |b|
        next unless b.kind.param? || b.kind.block_param?
        @param_texts[b.id] = text.byte_slice(b.decl_range.start, b.decl_range.size)
      end
      self
    end

    # -- environment ------------------------------------------------------------

    private def assign(b : HIR::BindingId, ty : TyId) : Nil
      if @captured.includes?(b) && (all = @captured_types[b]?)
        # Captured (second pass): the join of every assignment in the body.
        ty = join(all, ty)
      end
      @env[b] = ty
      return if @replaying && !@collecting
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
      # Hard cap on block transfers: oscillating values (block results that
      # feed back into their own parameters) must not hang the server.
      budget = cfg.blocks.size * (MAX_VISITS + 2) * 4
      while (r = @pending.index(true)) && (budget -= 1) >= 0
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
    # Block holding each closure's `Enter`.
    @enter_block = {} of HIR::ExprId => Int32
    @reentries = Hash(Int32, Int32).new(0)

    private def transfer(b : Flow::Block, env : Env) : Bool
      @env = env.dup
      alive = true
      b.ops.each do |op|
        if op.kind.enter?
          @enter_block[op.expr] = b.id.value
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
      if @body.expr(id).kind.block? && (head = @enter_block[id]?)
        # The block's value feeds its own params (yield summaries keyed by
        # the block value): re-enter the closure, within the visit budget
        # (values can oscillate between iterations).
        @reentries[head] += 1
        enqueue(head) if @in.has_key?(head) && @reentries[head] <= MAX_VISITS
      end
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
      # Captured locals are not narrowed by truthiness (`if x`, if_var.md);
      # the compiler still narrows them by `is_a?`, `nil?` and `case`.
      if test.kind.truthy? && !@captured.empty?
        truthy_locals(test.cond).each { |k| facts.delete(k) if @captured.includes?(k) }
      end
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
      c = @body.expr(cond)
      # `case {a, b}` / `when {T, U}`: each element against its local. A
      # match fixes every element; a miss says nothing about any one.
      if s.kind.collection? && s.syntax.tuple_node? && c.kind.collection? && c.syntax.tuple_node?
        return result unless truthy && s.children.size == c.children.size
        s.children.zip(c.children) do |se, ce|
          case_facts(ce, se, true).each { |k, v| result[k] = v }
        end
        return result
      end
      # `case x = expr`: the assigned local.
      if s.kind.assign? && (tgt = s.children[0]?) && @body.expr(tgt).kind.local_ref?
        s = @body.expr(tgt)
      end
      return result unless s.kind.local_ref?
      b = s.binding || return result
      t = @env[b]? || return result
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
                 elsif c.bare_call? && c.name == "_"
                   nil
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
      t = s.expr.try { |x| source_value(x) } || nil_t
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
           when .self?         then self_at(e)
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
           when .while?, .until? then merge_type(id)
           when .seq?          then e.children.last?.try { |c| operand(c) } || nil_t
           when .not?          then @table.named!("Bool")
           when .collection?   then collection(e)
           when .type_of?
             # `typeof(a, b)` as a value is the type: its metaclass.
             ts = e.children.map { |c| operand(c) }
             ts.empty? ? @table.unknown : @table.metaclass(union_or_unknown(ts))
           when .proc_literal? then eval_proc(e)
           when .block?
             # `&proc` passes a value; literal and `&.foo` blocks merge
             # their exits.
             e.syntax.block_argument? ? (e.children.first?.try { |c| operand(c) } || @table.unknown) : merge_type(id)
           when .splat?, .double_splat? then e.children.first?.try { |c| operand(c) } || @table.unknown
           when .return?, .break?, .next?
             @jump_values[id] = e.children.size > 1 ? @table.tuple(e.children.map { |c| operand(c) }) : nil_t
             @table.no_return
           when .yield?
             ts = e.children.map { |c| operand(c) }
             ts = [] of TyId if @replaying
             if (r = e.receiver) && !@replaying
               rt = operand(r)
               @with_self = (ws = @with_self) ? join(ws, rt) : rt
             end
             ts.each_with_index do |t, i|
               (@yield_types[i]? || (@yield_types << [] of TyId; @yield_types[i])) << t
             end
             # Value of the caller's block, when the summary was asked for
             # one call site; otherwise NoReturn: the block's value is not
             # known yet and contributes nothing (`Pending` seed), so
             # `memo = yield memo, e` keeps memo's other assignments.
             @yield_value || (@summarising ? @table.pending : @table.unknown)
           when .other?
             case e.syntax
             when .uninitialized_var?
               e.type_text.try { |t| parse_type(t) } || @table.unknown
             when .pointerof?
               e.children.first?.try { |c| @table.named?("Pointer", [operand(c)]) } || @table.unknown
             when .sizeof?, .instance_sizeof?, .alignof?, .instance_alignof?, .offsetof?
               @table.named!("Int32")
             when .method_proc?
               method_proc_type(e)
             when .nilable_constant?
               e.type_text.try { |tt| t = parse_type(tt); @table.unknown?(t) ? nil : @table.metaclass(t) } || @table.unknown
             else
               @table.unknown
             end
           when .global?       then special_var_type(e)
           else
             @table.unknown
           end
      @types[id] = ty
      ty
    end

    # `->recv.name(T, U)`: Proc(T, U, R) with R the return of the overload
    # those param types select.
    private def method_proc_type(e : HIR::Expr) : TyId
      name = e.name || return @table.unknown
      params = (e.type_text || "").split('\u0000', remove_empty: true).map { |t| parse_type(t) }
      return @table.unknown if params.any? { |p| @table.unknown?(p) }
      recv = e.receiver.try { |r| operand(r) } || implicit_self(e)
      groups = method_groups(recv, name)
      groups = [{@table.unknown, top_level_sites(name)}] if groups.empty? && e.receiver.nil?
      site = CallSite.new(params.map { |p| CallArg.new(p) }, [] of {String, CallArg}, false, false)
      ret = return_type_of(resolver.resolve(groups, site), nil)
      @table.proc(params, ret)
    end

    # `$~` / `$1` (the last regex match in this scope): `$~` and `$1` raise
    # when there is no match, the `?` forms are nilable. `$?` is the last
    # `Process::Status`. Other globals are not modelled.
    private def special_var_type(e : HIR::Expr) : TyId
      return @table.unknown unless e.syntax.special_variable?
      name = e.name || return @table.unknown
      t = case name.rchop('?')
          when "$~" then @table.named?("Regex::MatchData")
          when "$?" then @table.named?("Process::Status")
          when /\A\$\d+\z/ then @table.named?("String")
          end
      t ||= @table.unknown
      name.ends_with?('?') && !@table.unknown?(t) ? @table.nilable(t) : t
    end

    # Namespace lookup for code outside defs (`class Foo; self.x; end`),
    # set by the caller; nil inside defs.
    property type_body_self : Proc(UInt32, TyId?)? = nil

    private def self_at(e : HIR::Expr) : TyId
      @type_body_self.try(&.call(e.range.start)) || @ctx.self_type
    end

    # Implicit receiver: `self` at the call site, or the `with x yield`
    # receiver of the innermost enclosing block that has one.
    private def implicit_self(e : HIR::Expr) : TyId
      unless @block_self.empty?
        cur = @parent[e.id]?
        while c = cur
          if ws = @block_self[c]?
            return ws
          end
          cur = @parent[c]?
        end
      end
      self_at(e)
    end

    # The `with x yield` receiver for code at *offset*, if inside such a
    # block.
    def with_self_at(offset : UInt32) : TyId?
      @block_self.select { |id, _| @body.expr(id).range.contains?(offset) }
        .min_by? { |id, _| @body.expr(id).range.size }.try(&.[1])
    end

    @with_yield = {} of {Int32, UInt32, UInt32} => Bool

    private def with_yield_def?(site : Semantics::Site) : Bool
      r = site.item.range
      @with_yield[{site.file.value.to_i32, r.start, r.end}] ||= begin
        node = @source_loader.try(&.call(site))
        !!node.try { |n| n.tree.text.byte_slice(n.start_byte, n.end_byte - n.start_byte).matches?(/\bwith\b[^\n]*\byield\b/) }
      end
    end

    # `with` receivers per block expression (from the callee's summary).
    @block_self = {} of HIR::ExprId => TyId

    # The `with x yield` receiver of *call*'s viable candidates.
    private def with_self_of(call : HIR::Expr) : TyId?
      return nil if summary_depth <= 0
      # Cheap textual pre-check: only defs whose source has `with ... yield`.
      res = @resolutions[call.id]? || resolve_call(call)
      cands = res.candidates.select { |c| with_yield_def?(c.match.site) }
      return nil if cands.empty?
      ts = cands.compact_map do |c|
        summary(c, nil, for_yields: true).with_self.try { |t| Subst.apply(@table, t, c.match.bindings) }
      end
      ts.empty? ? nil : union_or_unknown(ts)
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
      when .pseudo_constant?
        case e.text
        when "__LINE__", "__END_LINE__" then @table.named!("Int32")
        when "__FILE__", "__DIR__"      then @table.named!("String")
        else                                 @table.unknown
        end
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
      @table.named!(Infer.unsuffixed_int_type(text))
    end

    # Type of a suffix-less integer literal: Int32 if the value fits, else
    # Int64, else UInt64 (literals.md, integers).
    def self.unsuffixed_int_type(text : String) : String
      t = text.delete('_')
      neg = t.starts_with?('-')
      t = t.lchop('-').lchop('+')
      base = case t[0, 2]
             when "0x" then 16
             when "0o" then 8
             when "0b" then 2
             else           10
             end
      digits = base == 10 ? t : t[2..]
      v = digits.to_u128?(base) || return "Int32"
      if neg
        return "Int32" if v <= 2_u128**31
        return "Int64" if v <= 2_u128**63
      else
        return "Int32" if v < 2_u128**31
        return "Int64" if v < 2_u128**63
      end
      "UInt64"
    end

    private def collection(e : HIR::Expr) : TyId
      elems = [] of TyId
      # `*x` elements: a tuple contributes its elements; in arrays (and
      # array-likes) any enumerable contributes its element type.
      tuple_splat_unknown = false
      e.children.each do |c|
        ce = @body.expr(c)
        return @table.unknown if ce.kind.missing?
        unless ce.kind.splat?
          elems << operand(c)
          next
        end
        st = operand(c)
        t = @table[st]
        if t.kind.tuple?
          elems.concat(t.args)
        elsif e.syntax.tuple_node?
          tuple_splat_unknown = true
        else
          elems << (enumerable_element(st) || @table.unknown)
        end
      end
      return @table.unknown if tuple_splat_unknown
      of_key = of_value = nil.as(TyId?)
      named = [] of {String, TyId}
      e.named_args.each do |(n, v)|
        case n
        when HIR::LowerBody::OF_KEY   then of_key = instance_of(operand(v))
        when HIR::LowerBody::OF_VALUE then of_value = instance_of(operand(v))
        else                               named << {n, operand(v)}
        end
      end
      case e.syntax
      when .array_node?
        elem = of_key || e.type_text.try { |t| parse_type(t) } || (elems.empty? ? @table.unknown : union_or_unknown(elems))
        @table.named!("Array", [elem])
      when .hash_node?
        if k = e.type_text
          @table.named!("Hash", [of_key || parse_type(k), of_value || e.type_text2.try { |v| parse_type(v) } || @table.unknown])
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
        # `..2` / `1..`: the missing bound is Nil (lowering records which
        # bound a single child is).
        b, en = case elems.size
                when 2 then {elems[0], elems[1]}
                when 1 then e.type_text2 == "begin" ? {elems[0], nil_t} : {nil_t, elems[0]}
                else        {nil_t, nil_t}
                end
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

    # T of the `Enumerable(T)` (or `Iterator(T)`) ancestor of *t*.
    private def enumerable_element(t : TyId) : TyId?
      ty = @table[t]
      case ty.kind
      when .tuple?
        return union_or_unknown(ty.args)
      when .named?
        def_id = ty.def_id.not_nil!
        bindings = generic_bindings(def_id, ty.args)
        enum_id = map.lookup_path("::Enumerable") || return nil
        return nil unless map.ancestors(def_id).includes?(enum_id)
        tparam = map[enum_id].type_params.first? || return nil
        # Bindings propagate through `include Enumerable(T)` refs.
        bindings[tparam]?
      end
    end

    # Instance type of a metaclass (`typeof(x)` value → type of x).
    private def instance_of(t : TyId) : TyId
      ty = @table[t]
      ty.kind.metaclass? ? ty.args[0] : @table.unknown
    end

    private def union_or_unknown(ts : Array(TyId)) : TyId
      return @table.unknown if ts.empty?
      u = @table.union(ts)
      @table.members(u).size > MAX_UNION ? @table.unknown : u
    end

    private def const_type(e : HIR::Expr) : TyId
      text = e.name || return @table.unknown
      # `alias IntP = Pointer(Int32)` keeps its args through the parser
      # (lookup_path alone drops them).
      if !text.includes?('(') && (raw = alias_at(text)) && map[raw].kind.alias?
        t = parse_type(text)
        return @table.metaclass(t) unless @table.unknown?(t)
      end
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
          # Enum members are values of the enum, whatever their value text.
          if (eo = enum_owner(o, site))
            return @table.named(eo)
          end
          return const_value_type(site, o)
        end
        # `@[Flags]` enums get `None` and `All` from the compiler.
        if name.in?("None", "All") && map[o].kind.enum? && flags_enum?(o)
          return @table.named(o)
        end
      end
      @table.unknown
    end

    private def flags_enum?(id : Semantics::TypeId) : Bool
      map[id].sites.any? { |s| s.item.annotations.any? { |a| a == "Flags" || a == "::Flags" } }
    end

    # The type item *text* names, without following aliases.
    private def alias_at(text : String) : Semantics::TypeId?
      names = text.lchop("::").split("::")
      cur = text.starts_with?("::") ? Semantics::DefMap::PROGRAM : @ctx.ns
      names.each_with_index do |n, i|
        cur = map.lookup_path_item(n, cur, lookup_self: i == 0, lookup_in_namespace: i == 0) || return nil
      end
      cur
    end

    # The enum that declares *site* when *site* is one of its members
    # (lookup may find it through an ancestor of *from*).
    private def enum_owner(from : Semantics::TypeId, site : Semantics::Site) : Semantics::TypeId?
      map.ancestors(from).find do |a|
        map[a].kind.enum? && map[a].members[site.item.name]?.try(&.includes?(site))
      end
    end

    # `value` of an enum: its base type (`enum E : UInt8`), Int32 by default.
    private def enum_base(id : Semantics::TypeId) : TyId
      info = map[id]
      base = info.sites.compact_map(&.item.header.try(&.base_type)).first?
      base ? TypeExprParser.parse(base, @table, info.namespace || Semantics::DefMap::PROGRAM) : @table.named!("Int32")
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
      @const_cache[key] ||= begin
        t = Infer.value_text_type(value, @table, owner)
        @table.unknown?(t) ? const_expr_type(site, owner) : t
      end
    end

    MAX_CONST_BYTES = 4096

    @value_parser : Syntax::Parser? = nil

    # Parses the first ~1 KB of a big literal value, closed off after the
    # last complete top-level entry: `Slice(UInt64).literal(1, 2, 3, ...)`
    # → `Slice(UInt64).literal(1, 2)`, `{"a" => 1, ...}` → `{"a" => 1}`.
    private def truncated_value(text : String) : Syntax::Node?
      stripped = text.strip
      if stripped.starts_with?("begin") && stripped.ends_with?("end")
        # `begin; data = Array(T).new(n); put(...) x1000; data; end`: keep
        # the first statements and the final value.
        lines = stripped.lines
        body = lines[1, Math.min(4, lines.size - 2)] + lines[-2..-2]
        src = "x = begin\n" + body.join('\n') + "\nend"
        tree = (@value_parser ||= Syntax::Parser.new).parse(src)
        return tree.root.named_child(0).try(&.field(Syntax::Field::Rhs))
      end
      head = text.byte_slice(0, Math.min(text.bytesize, 1024))
      depth = 0
      opens = [] of Char
      last_cut = nil.as(Int32?)
      in_str = false
      head.each_char_with_index do |c, i|
        if in_str
          in_str = false if c == '"'
          next
        end
        case c
        when '"' then in_str = true
        when '(', '[', '{'
          opens << c
          depth += 1
        when ')', ']', '}'
          opens.pop?
          depth -= 1
        when ','
          last_cut = i if depth == 1
        end
      end
      cut = last_cut || return nil
      closers = {'(' => ')', '[' => ']', '{' => '}'}
      stack = [] of Char
      head[0, cut].each_char do |c|
        case c
        when '(', '[', '{' then stack << c
        when ')', ']', '}' then stack.pop?
        end
      end
      return nil unless stack.size == 1
      src = "x = " + head[0, cut] + closers[stack[0]]
      tree = (@value_parser ||= Syntax::Parser.new).parse(src)
      tree.root.named_child(0).try(&.field(Syntax::Field::Rhs))
    end

    # Infers a constant's value expression (`%w(a b)`, `[1, 2]`, calls) as
    # a tiny body in the owner's namespace, through the summary cache.
    private def const_expr_type(site : Semantics::Site, owner : Semantics::TypeId) : TyId
      cache = @summaries || return @table.unknown
      loader = @source_loader || return @table.unknown
      self_t = owner == Semantics::DefMap::PROGRAM ? @table.unknown : @table.metaclass(@table.named(owner))
      # Big data tables (`POW10_SPLIT = [...]` with thousands of entries)
      # are typed from a prefix: their first elements decide the element
      # type in practice, and lowering them all costs hundreds of ms.
      cache.get(site, self_t, [] of TyId) do
        rhs = if site.item.range.size > MAX_CONST_BYTES
                # Data table: infer a truncated copy (first entries) rather
                # than parsing thousands of elements.
                truncated_value(site.item.detail || "") || next nil
              else
                node = loader.call(site) || next nil
                node.field(Syntax::Field::Rhs) || next nil
              end
        ctx = DefContext.new(owner, self_t, map[owner].type_params)
        inner = Infer.new(HIR::LowerBody.lower(rhs), ctx, @table)
        inner.source_loader = loader
        inner.summaries = cache
        inner.summarising = true
        inner.run
        Summaries::Summary.new(inner.return_type, [] of TyId)
      end.returns.tap { |t| return @table.unknown if t == @table.pending }
    end

    def self.value_text_type(value : String, table : TypeTable, ns : Semantics::TypeId) : TyId
      v = value.strip
      case v
      when /\A-?\d[\d_]*(_?[iu]\d+)?\z/ then table.named!(v =~ /([iu]\d+)\z/ ? ($1.starts_with?('i') ? "Int#{$1[1..]}" : "UInt#{$1[1..]}") : unsuffixed_int_type(v))
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
        assigned = [] of Semantics::Site
        if sites = info.members[name]?
          sites.each do |site|
            next unless site.item.kind == kind
            if site.item.origin.assigned?
              assigned << site
              next
            end
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
        unless assigned.empty?
          return assigned_ivar_type(map, table, anc, name, class_var, assigned)
        end
      end
      table.unknown
    end

    # Type of an undeclared ivar from its `@x = v` assignments in defs
    # (type_inference.md rules 1-5): literals, `T.new`, class-method calls
    # with a declared return, restricted or defaulted params. Unknown if
    # any assignment can't be typed by these rules (the compiler would
    # reject the program). Nil joins in when some `initialize` of the type
    # doesn't assign it (or the type has none, for ivars only set later).
    def self.assigned_ivar_type(map : Semantics::DefMap, table : TypeTable, owner : Semantics::TypeId,
                                name : String, class_var : Bool, sites : Array(Semantics::Site)) : TyId
      info = map[owner]
      types = [] of TyId
      sites.each do |site|
        t = assigned_value_type(map, table, owner, site.item.detail || "")
        return table.unknown if table.unknown?(t)
        types << t
      end
      unless class_var
        # Nil unless every `initialize` of the type assigns it.
        inits = (info.members["initialize"]? || [] of Semantics::Site).select(&.item.kind.def?)
        all_init = !inits.empty? && inits.all? do |i|
          sites.any? { |s| s.file == i.file && i.item.range.covers?(s.item.range) }
        end

        types << table.named!("Nil") unless all_init
      else
        # Class vars are nil until assigned unless assigned at the type
        # level (those are declarations, handled above).
        types << table.named!("Nil")
      end
      table.union(types.uniq)
    end

    private def self.assigned_value_type(map : Semantics::DefMap, table : TypeTable, owner : Semantics::TypeId, text : String) : TyId
      ns = map[owner].namespace || Semantics::DefMap::PROGRAM
      if text.starts_with?(": ")
        return TypeExprParser.parse(text[2..], table, owner, map[owner].type_params)
      end
      v = text.starts_with?("= ") ? text[2..] : text
      t = value_text_type(v, table, owner)
      return t unless table.unknown?(t)
      t = literal_expr_type(v, table, owner)
      return t unless table.unknown?(t)
      # `Type.method(...)` (rule 4): a class method with a declared return,
      # or `new`.
      if m = v.match(/\A((?:::)?[A-Z][\w:]*(?:\([^)]*\))?)\.(\w+[?!]?)/)
        tt = TypeExprParser.parse(m[1], table, owner)
        tr = table[tt]
        return table.unknown unless tr.kind.named?
        id = tr.def_id.not_nil!
        return tt if m[2] == "new"
        map.lookup_member(id, "self.#{m[2]}").each do |site|
          r = site.item.signature.try(&.return_type) || next
          return TypeExprParser.parse(r, table, id, map[id].type_params, tt)
        end
        # Constructor-like class method without a return type whose body
        # ends in `new(...)` (the book's rule 4 body case).
        map.lookup_member(id, "self.#{m[2]}").each do |site|
          return tt if class_method_news?(site)
        end
      end
      table.unknown
    end

    # Literal values (`[1]`, `{1, "a"}`, `cond ? 1.5 : nil`, `1..2`) typed
    # by inferring the text as a small body without calls into other
    # code: only literals, collections, and `?:`/`||` joins of them.
    # Rule 1 of type_inference.md (and its literal-only spirit).
    def self.literal_expr_type(text : String, table : TypeTable, owner : Semantics::TypeId) : TyId
      return table.unknown if text.size > 512
      tree = Syntax::Parser.new.parse("__v = (#{text})")
      rhs = tree.root.named_child(0).try(&.field(Syntax::Field::Rhs)) || return table.unknown
      return table.unknown if rhs.has_error?
      body = HIR::LowerBody.lower(rhs)
      return table.unknown unless literal_value?(body, body.root)
      ctx = DefContext.new(owner, table.unknown, [] of String)
      inf = Infer.new(body, ctx, table).run
      t = inf.type_of(body.root)
      table.unknown?(t) ? table.unknown : t
    end

    # Literal forms: literals and collections of them; for `c ? a : b` and
    # `if`, the branch values (the condition can be anything).
    private def self.literal_value?(body : HIR::Body, id : HIR::ExprId) : Bool
      e = body.expr(id)
      case e.kind
      when .literal?, .nop?        then true
      when .collection?            then e.children.all? { |c| literal_value?(body, c) } && e.named_args.all? { |(_, v)| literal_value?(body, v) }
      when .if?, .unless?          then e.children.size == 3 && literal_value?(body, e.children[1]) && literal_value?(body, e.children[2])
      when .seq?                   then e.children.last?.try { |c| literal_value?(body, c) } || false
      else                              false
      end
    end

    # Constructor-like class methods are recognised by the caller-provided
    # source check below (set by `Typing`); without it, not at all.
    class_property news_check : Proc(Semantics::Site, Bool)? = nil

    private def self.class_method_news?(site : Semantics::Site) : Bool
      @@news_check.try(&.call(site)) || false
    end

    # -- assignment ---------------------------------------------------------------

    private def visit_assign(e : HIR::Expr) : TyId
      target, value = e.children[0]?, e.children[1]?
      ty = value ? operand(value) : @table.unknown
      write_target(target, ty) if target
      ty
    end

    private def visit_multi_assign(e : HIR::Expr) : TyId
      n = e.target_count
      targets = e.children[0, n]
      values = e.children[n..].map { |v| operand(v) }
      splat = targets.index { |t| @body.expr(t).kind.splat? }
      # `a, b = tuple`: the tuple's elements; `a, b = xs`: the element type.
      elems = values
      many = values.size == 1 && targets.size > 1
      if many
        t = @table[values[0]]
        elems = if t.kind.tuple?
                  t.args
                elsif t.kind.union? && !t.args.empty? && t.args.all? { |m| @table[m].kind.tuple? && @table[m].args.size == @table[t.args[0]].args.size }
                  # A union of same-size tuples: per-position unions.
                  n = @table[t.args[0]].args.size
                  (0...n).map { |i| union_or_unknown(t.args.map { |m| @table[m].args[i] }) }
                end
      end
      targets.each_with_index do |tgt, i|
        ty = if es = elems
               if splat.nil?
                 es[i]? || @table.unknown
               elsif i < splat
                 es[i]? || @table.unknown
               elsif i == splat
                 # `*rest` takes what the targets around it leave: a tuple.
                 tail = targets.size - splat - 1
                 count = es.size - splat - tail
                 count >= 0 ? @table.tuple(es[splat, count]) : @table.unknown
               else
                 es[es.size - (targets.size - i)]? || @table.unknown
               end
             else
               # Not a tuple: each target is an element; `*rest` an array.
               el = element_type(values[0])
               i == splat ? (@table.named?("Array", [el]) || @table.unknown) : el
             end
        write_target(tgt, ty)
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
             call_return(current, op, [vt], nil) || primitive_op(current, op, [vt]) || current
           end
      write_target(target, ty)
      ty
    end

    private def visit_type_decl(e : HIR::Expr) : TyId
      value = e.children[0]?.try { |c| operand(c) }
      b = e.binding
      declared = b.try { |bid| declared_local(bid) }
      # Decision 3: the value's type within the declaration (`x : Int32? =
      # nil` is Nil here); without a value, the declared type.
      ty = if declared && value
             declared_flow(declared, value)
           else
             declared || value || @table.unknown
           end
      b.try { |bid| assign(bid, ty) }
      ty
    end

    # Declared type of a `x : T` local, if any.
    private def declared_local(b : HIR::BindingId) : TyId?
      bd = @body.binding(b)
      return nil unless bd.kind.type_decl?
      bd.restriction.try { |r| t = parse_type(r); @table.unknown?(t) ? nil : t }
    end

    # Assigning *value* to a local declared *declared*: the value's members
    # that fit (autocast literals take the declared type); the declared
    # type when nothing fits or the value is unknown.
    private def declared_flow(declared : TyId, value : TyId) : TyId
      return declared if @table.unknown?(value)
      kept = @table.members(value).select { |m| subtype?(m, declared) }
      kept.size == @table.members(value).size ? @table.union(kept) : declared
    end

    private def write_target(target : HIR::ExprId, ty : TyId) : Nil
      t = @body.expr(target)
      if t.kind.splat? && (inner = t.children[0]?)
        @types[target] = ty
        return write_target(inner, ty)
      end
      @types[target] = ty
      if (b = t.binding) && t.kind.local_ref?
        # A local declared `x : T` stays within T on later assignments.
        if declared = declared_local(b)
          ty = declared_flow(declared, ty)
        end
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
          when "responds_to?"
            # `x.responds_to?(:m)`: the members that have a method `m`.
            if (arg = e.children[0]?) && (sym = symbol_text(arg))
              (r = responds_narrowing(t, sym, truthy)) && (result[b] = r)
            end
          end
        end
      end
      result
    end

    # Locals that *cond* tests by truthiness (`x`, `x = v`, through `!`,
    # `&&`, `||`).
    private def truthy_locals(cond : HIR::ExprId) : Array(HIR::BindingId)
      e = @body.expr(cond)
      case e.kind
      when .local_ref? then e.binding.try { |b| [b] } || [] of HIR::BindingId
      when .assign?    then e.children[0]?.try { |t| @body.expr(t).binding }.try { |b| [b] } || [] of HIR::BindingId
      when .not?, .and?, .or?, .seq?
        e.children.flat_map { |c| truthy_locals(c) }
      else [] of HIR::BindingId
      end
    end

    # `:foo` / `:"foo="` as written.
    private def symbol_text(id : HIR::ExprId) : String?
      e = @body.expr(id)
      return nil unless e.kind.literal? && e.syntax.symbol_node?
      src = @source || return nil
      src.byte_slice(e.range.start, e.range.size).lchop(':').strip('"')
    end

    # Members of *t* that respond (truthy) / don't respond to *name*; nil
    # when unknown members make the split unsure.
    private def responds_narrowing(t : TyId, name : String, truthy : Bool) : TyId?
      return nil if @table.unknown?(t)
      yes = [] of TyId
      no = [] of TyId
      @table.members(t).each do |m|
        groups = method_groups(m, name)
        has = groups.any? { |(_, ms)| !ms.empty? } || !primitive_op(m, name, [] of TyId).nil?
        (has ? yes : no) << m
      end
      kept = truthy ? yes : no
      kept.empty? ? nil : @table.union(kept)
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
      # A declared return (`-> : Int32 | String { 1 }`) is the proc's type.
      ret = e.type_text.try { |t| parse_type(t) } || @types[blk.id]? || @table.unknown
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
      if owner && owner.kind.call? && (ws = with_self_of(owner))
        @block_self[id] = ws
      end
      if e.syntax.implicit_object_call?
        @implicit_args[id] = param_types[0]? || @table.unknown
      end
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

    # Value a call's block produces: its body's value, or for `&proc` /
    # `&->foo` the proc's return type.
    private def block_value(b : HIR::ExprId) : TyId?
      t = @types[b]? || return nil
      return t unless @body.expr(b).syntax.block_argument?
      pt = @table[t]
      pt.kind.proc? ? pt.args.last : @table.unknown
    end

    # Block arg types for a call's block.
    private def closure_param_types(call : HIR::Expr) : Array(TyId)
      name = call.name || return [] of TyId
      recv_t = call.receiver.try { |r| operand(r) }
      return [] of TyId if name.in?("as", "as?")
      return [@table.without_nil(recv_t)] if name == "try" && recv_t
      # The block's value from the previous closure iteration feeds yield
      # summaries whose arguments depend on it (`reduce(memo) { |acc, x| }`).
      block_ret = call.block.try { |b| block_value(b) }
      block_types_for(resolve_call(call).candidates, block_ret)
    end

    # -- calls --------------------------------------------------------------------

    private def visit_call(e : HIR::Expr) : TyId
      t = visit_call_value(e)
      # `break v` in the call's block: v is also a possible value.
      if cfg.merges.has_key?(e.id)
        b = merge_type(e.id)
        return join(t, b) unless b == @table.no_return
      end
      t
    end

    private def visit_call_value(e : HIR::Expr) : TyId
      recv_t = e.receiver.try { |r| operand(r) }
      args = e.children.map { |c| operand(c) }
      block_ret = e.block.try { |b| block_value(b) }
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


      # `Enumerable.element_type(x)` / `Iterator.element_type(x)`: what x
      # yields from `each` (generic arg of Enumerable/Iterator ancestors).
      if name == "element_type" && args.size == 1 && recv_t && @table[recv_t].kind.metaclass?
        if (et = enumerable_element(args[0])) && !@table.unknown?(et)
          return et
        end
      end

      if name == "try" && recv_t && e.block
        # `x.try { |v| ... }`: v is x without Nil. The block runs for the
        # non-nil members (`Object#try`), `Nil#try` returns nil. With an
        # unknown receiver the result is still the block's value or nil.
        inner = block_ret || @table.unknown
        if @table.unknown?(recv_t)
          return @table.unknown?(inner) ? inner : @table.nilable(inner)
        end
        members = @table.members(recv_t)
        has_nil = members.any? { |m| @table.nil_type?(m) }
        return nil_t if members.all? { |m| @table.nil_type?(m) }
        return inner if @table.unknown?(inner) || !has_nil
        return @table.nilable(inner)
      end

      if (r = redef_call(e))
        return r
      end

      if (lt = lib_member_call(receiver_type_of(e), name, e))
        return lt
      end

      # `obj.@x`: the receiver's ivar.
      if name.starts_with?('@') && recv_t
        ivar_owner = @table[recv_t].def_id
        return ivar_owner && @table[recv_t].kind.named? ? Infer.ivar_type(map, @table, ivar_owner, name, false, @ctx) : @table.unknown
      end

      recv_t ||= implicit_receiver(e)
      receiver_type = recv_t || implicit_self(e)
      if name == "value" && args.empty? && (rt = @table[receiver_type]).kind.named? && map[rt.def_id.not_nil!].kind.enum?
        return enum_base(rt.def_id.not_nil!)
      end
      res = resolve_call(e)
      if name == "new" && res.candidates.empty?
        # `Foo.new` without an explicit `self.new`: instance of Foo, with
        # generic args bound from the `initialize` it calls
        # (`MyBox.new(1)` → MyBox(Int32)).
        rt = @table[receiver_type]
        return instance_from_initialize(e, rt.args[0]) if rt.kind.metaclass?
      end
      @resolutions[e.id] = res
      if res.candidates.empty? && (prim = primitive_op(receiver_type, name, args))
        return prim
      end
      if res.candidates.empty? && (gen = generated_method(receiver_type, name, args))
        return gen
      end
      if (u = type_union_op(receiver_type, name, args))
        return u
      end
      declared = return_type_of(res, block_ret)
      if @table.unknown?(declared)
        # Number operators whose resolved stdlib bodies don't summarise
        # (`Float#//`, macro-generated `Int#/`), then comparisons: `==`,
        # `<`, ... are Bool in practice (declared returns win above).
        if prim = primitive_op(receiver_type, name, args)
          return prim
        end
        return @table.named!("Bool") if COMPARISONS.includes?(name) && args.size == 1 && !res.candidates.empty?
      end
      # Contracts only fill in what resolution could not type, and only
      # for stdlib owners (user code overriding `sum` keeps its type).
      if partially_unknown?(declared) && stdlib_candidates?(res) && (c = contract(e, receiver_type, name, args, block_ret))
        return c
      end
      declared
    end

    private def instance_from_initialize(call : HIR::Expr, inst : TyId) : TyId
      it = @table[inst]
      return inst unless it.kind.named? && it.args.empty?
      def_id = it.def_id.not_nil!
      tparams = map[def_id].type_params
      return inst if tparams.empty?
      open = @table.named(def_id, tparams.map { |p| @table.type_param(p) })
      res = resolver.resolve(method_groups(open, "initialize"), call_site(call))
      bindings = {} of String => TyId
      res.candidates.each do |c|
        sig = c.match.site.item.signature || next
        (c.arg_params + c.named_params).each_with_index do |pi, i|
          next unless pi && (r = sig.params[pi].restriction) && (a = c.arg_types[i]?)
          next if @table.unknown?(a) || !sig.params[pi].kind.positional?
          pattern = TypeExprParser.parse(r, @table, c.match.owner, map[c.match.owner].type_params + sig.free_vars)
          Subst.unify(@table, pattern, a, bindings)
        end
      end
      args = tparams.map { |p| bindings[p]? }
      return inst if args.any?(&.nil?)
      @table.named(def_id, args.compact)
    end

    private def receiver_type_of(e : HIR::Expr) : TyId?
      e.receiver.try { |r| operand(r) }
    end

    # Calls into C bindings (c_bindings/*.md): `Lib.fun(...)` returns the
    # fun's declared type (`Void` → Nil), `Lib.var` / `Lib.var = v` a
    # `$var`, and `struct.field` / `struct.field = v` on lib structs and
    # unions the field type. Arguments are not checked: C calls convert
    # them implicitly (`to_unsafe`, numbers), and only the name and the
    # arity matter (variadic funs take any extra).
    private def lib_member_call(recv : TyId?, name : String, e : HIR::Expr) : TyId?
      r = @table[recv || return nil]
      if r.kind.metaclass? && (lt = @table[r.args[0]]).kind.named?
        lib_id = lt.def_id.not_nil!
        return nil unless map[lib_id].kind.lib?
        base = name.rchop('=')
        map[lib_id].members[base]?.try &.each do |site|
          item = site.item
          case item.kind
          when .fun?
            sig = item.signature || next
            n = e.children.size
            next unless n == sig.params.size || (sig.variadic && n >= sig.params.size)
            # `out x` arguments: x is the pointee of the param's type.
            e.children.each_with_index do |c, i|
              ce = @body.expr(c)
              next unless ce.kind.other? && ce.syntax.out? && (tgt = ce.children[0]?)
              pt = sig.params[i]?.try(&.restriction).try { |r| @table[c_type(r, lib_id)] }
              elem = pt && pt.kind.named? && map[pt.def_id.not_nil!].full_name == "Pointer" ? pt.args[0]? : nil
              write_target(tgt, elem || @table.unknown)
            end
            ret = sig.return_type || return nil_t
            return ret == "Void" ? nil_t : c_type(ret, lib_id)
          when .c_var?
            return c_type(item.detail || next, lib_id)
          end
        end
        return nil
      end
      if r.kind.named?
        owner = r.def_id.not_nil!
        info = map[owner]
        return nil unless info.kind.c_struct? || info.kind.c_union?
        base = name.rchop('=')
        info.members[base]?.try &.each do |site|
          next unless site.item.kind.c_field?
          return c_type(site.item.detail || next, info.namespace || owner)
        end
      end
      nil
    end

    # A type written inside a lib (`Point*`, `Size`, `Int32 -> Int32`).
    private def c_type(text : String, scope : Semantics::TypeId) : TyId
      TypeExprParser.parse(text, @table, scope)
    end

    # The def this body belongs to (for `previous_def` and `super`).
    property current_def : Semantics::Site? = nil

    # `previous_def` / `super` (with or without arguments): the def this
    # one redefines, or the same method in the nearest ancestor. Bare
    # forms pass the current def's own arguments.
    private def redef_call(e : HIR::Expr) : TyId?
      name = e.name || return nil
      return nil unless e.receiver.nil? && name.in?("previous_def", "super")
      cur = @current_def || return @table.unknown
      owner = @ctx.ns
      sig = cur.item.signature
      class_side = !sig.try(&.receiver).nil?
      key = class_side ? "self.#{cur.item.name}" : cur.item.name
      cands = if name == "previous_def"
                (map[owner].members[key]? || [] of Semantics::Site).select do |s|
                  s != cur && s.item.kind.def? && Infer.redefines?(cur, s)
                end.sort_by { |s| {s.file.value, s.item.range.start} }.last(1)
              else
                found = [] of Semantics::Site
                map.ancestors(owner).each do |anc|
                  next if anc == owner
                  if (ss = map[anc].members[key]?) && !(defs = ss.select(&.item.kind.def?)).empty?
                    found = defs
                    break
                  end
                end
                found
              end
      return @table.unknown if cands.empty?
      # Arguments: as written, or the current def's params when bare.
      site = e.text == "()" || !e.children.empty? || !e.named_args.empty? ? call_site(e) : bare_redef_site
      self_t = class_side ? self_for(@ctx.self_type) : @ctx.self_type
      st = @table[self_t]
      bindings = st.kind.named? ? generic_bindings(st.def_id.not_nil!, st.args) : {} of String => TyId
      matches = cands.map { |s| MethodMatch.new(s, owner_of(owner, s), bindings) }
      return_type_of(resolver.resolve([{self_t, matches}], site), e.block.try { |b| block_value(b) })
    end

    # Call site for a bare `super` / `previous_def`: the current def's
    # params, with their current types.
    private def bare_redef_site : CallSite
      args = [] of CallArg
      @body.bindings.each do |b|
        next unless b.kind.param?
        args << CallArg.new(@env[b.id]? || @table.unknown)
      end
      CallSite.new(args, [] of {String, CallArg}, false, false)
    end

    # `A | B` on types (`Class.|`, whose body is `typeof(...)`): the
    # metaclass of the union.
    private def type_union_op(recv : TyId, name : String, args : Array(TyId)) : TyId?
      return nil unless name == "|" && args.size == 1
      a, b = @table[recv], @table[args[0]]
      return nil unless a.kind.metaclass? && b.kind.metaclass?
      @table.metaclass(@table.union([a.args[0], b.args[0]]))
    end

    # Methods the compiler defines without source: `Proc#call`, enum
    # member predicates (`Color::Red` → `#red?`).
    private def generated_method(recv : TyId, name : String, args : Array(TyId)) : TyId?
      t = @table[recv]
      if t.kind.proc? && name == "call"
        return t.args.last
      end
      if t.kind.proc? && name == "arity"
        return @table.named!("Int32")
      end
      if t.kind.named? && name.ends_with?('?') && args.empty?
        info = map[t.def_id.not_nil!]
        if info.kind.enum?
          member = name.rchop('?')
          if info.members.any? { |k, sites| k.underscore == member && sites.any?(&.item.kind.constant?) }
            return @table.named!("Bool")
          end
        end
      end
      nil
    end

    # Stdlib methods whose result type the compiler computes from macros or
    # literal arguments, which summaries cannot see (architecture §19:
    # block/collection contracts). Only applied to stdlib receivers.
    private def contract(e : HIR::Expr, recv : TyId, name : String, args : Array(TyId), block_ret : TyId?) : TyId?
      t = @table[recv]
      # A union of (named) tuples: each member's answer, joined (decision
      # 2: unions of tuples stay unions; indexing gives the per-position
      # union).
      if t.kind.union? && t.args.all? { |m| k = @table[m].kind; k.tuple? || k.named_tuple? }
        parts = t.args.map { |m| contract(e, m, name, args, block_ret).as(TyId?) || return nil }
        return union_or_unknown(parts)
      end
      case t.kind
      when .tuple?
        # `t[0]` with a literal index: that element (the compiler types
        # tuple indexing by literal per element).
        if name.in?("[]", "[]?", "at") && e.children.size == 1
          arg = @body.expr(e.children[0])
          if arg.kind.literal? && arg.syntax.integer? && (i = arg.text.try(&.to_i?))
            i += t.args.size if i < 0
            if el = t.args[i]?
              return el
            end
            return name == "[]?" ? nil_t : @table.no_return
          end
          return union_or_unknown(t.args) if name == "[]"
        end
      when .named_tuple?
        # `nt[:x]` / `nt["x"]` with a literal key.
        if name.in?("[]", "[]?") && e.children.size == 1
          arg = @body.expr(e.children[0])
          if arg.kind.literal? && (arg.syntax.symbol_node? || arg.syntax.string_node?) && (src = @source)
            key = src.byte_slice(arg.range.start, arg.range.size).lchop(':').strip('"')
            if i = t.names.index(key)
              return t.args[i]
            end
            return name == "[]?" ? nil_t : @table.no_return
          end
        end
      when .named?
        owner = map[t.def_id.not_nil!].full_name
        elem = enumerable_element(recv)
        case name
        when "sum", "product"
          # `sum` / `sum(&)`: element (or block) type; `sum(initial)`: initial.
          return args[0] if args.size == 1 && !@table.unknown?(args[0])
          return block_ret if block_ret && !@table.unknown?(block_ret)
          return elem if elem && args.empty? && !@table.unknown?(elem)
        when "flatten"
          if owner == "Array" && elem
            return @table.named!("Array", [flatten_element(elem)])
          end
        when "zip"
          if elem && !args.empty? && e.block.nil?
            others = args.map { |a| enumerable_element(a) || @table.unknown }
            return @table.named!("Array", [@table.tuple([elem] + others)])
          end
        end
      end
      nil
    end

    # Unknown, or a generic whose args are unknown (`Array(?)`).
    private def partially_unknown?(t : TyId) : Bool
      return true if @table.unknown?(t)
      ty = @table[t]
      ty.kind.named? && ty.args.any? { |a| @table.unknown?(a) }
    end

    private def stdlib_candidates?(res : CallResolution) : Bool
      return true if res.candidates.empty? && res.family.empty?
      (res.candidates.empty? ? res.family : res.matches).all? do |m|
        STDLIB_OWNERS.includes?(map[m.owner].full_name)
      end
    end

    STDLIB_OWNERS = %w(Tuple NamedTuple Array Hash Enumerable Indexable Iterable Iterator Set Deque Slice StaticArray)

    # Element type of nested arrays, flattened (`Array(Array(Int32) | Int32)`
    # → Int32).
    private def flatten_element(t : TyId, depth = 0) : TyId
      return t if depth > 4
      parts = @table.members(t).map do |m|
        mt = @table[m]
        if mt.kind.named? && map[mt.def_id.not_nil!].full_name == "Array" && mt.args.size == 1
          flatten_element(mt.args[0], depth + 1)
        else
          m
        end
      end
      union_or_unknown(parts)
    end

    INT_TYPES   = %w(Int8 Int16 Int32 Int64 Int128 UInt8 UInt16 UInt32 UInt64 UInt128)
    FLOAT_TYPES = %w(Float32 Float64)
    ARITH       = %w(+ - * &+ &- &*)
    INT_ONLY    = %w(| & ^ unsafe_shl unsafe_shr unsafe_div unsafe_mod)
    COMPARE     = %w(== != < <= > >=)
    COMPARISONS = %w(== != === < <= > >=)
    CONVERSIONS = {"to_i" => "Int32", "to_u" => "UInt32", "to_f" => "Float64"}

    # Number primitives the stdlib declares in `{% for %}` loops
    # (primitives.cr), which the item tree cannot see: binary operators
    # between number types and `to_*` conversions. Unknown argument types
    # stay unknown (Int32 - Float64 is Float64).
    private def primitive_op(recv : TyId, name : String, args : Array(TyId)) : TyId?
      rn = number_name(recv) || return nil
      if args.empty?
        target = CONVERSIONS[name.rchop('!')]? || begin
          suffix = name.rchop('!').lchop?("to_") || return nil
          case suffix
          when /\Ai(\d+)\z/ then "Int#{$1}"
          when /\Au(\d+)\z/ then "UInt#{$1}"
          when /\Af(\d+)\z/ then "Float#{$1}"
          end
        end
        return target.try { |t| (INT_TYPES + FLOAT_TYPES).includes?(t) ? @table.named?(t) : nil }
      end
      return nil unless args.size == 1
      return @table.named!("Bool") if COMPARE.includes?(name)
      r_int = INT_TYPES.includes?(rn)
      an = number_name(args[0])
      if an.nil?
        return nil unless @table.unknown?(args[0])
        # Unknown argument: integer `&+`-style ops and bit ops always return
        # self; `+` does too unless the argument is a float, which is rare
        # enough in integer code that the compiler-like answer is `self`.
        # Floats return self for every arithmetic op.
        return recv if (r_int && (ARITH.includes?(name) || INT_ONLY.includes?(name))) || (!r_int && ARITH.includes?(name) && !name.starts_with?('&'))
        return nil
      end
      a_int = INT_TYPES.includes?(an)
      if ARITH.includes?(name)
        return recv if r_int && a_int
        return recv if !r_int && !name.starts_with?('&')
        return args[0] if r_int && !a_int && !name.starts_with?('&')
      end
      return recv if INT_ONLY.includes?(name) && r_int && a_int
      case name
      when "/"
        # Int / Int is Float64; otherwise the wider float involved.
        return @table.named!("Float64") if r_int && a_int
        return @table.named!(rn == "Float64" || an == "Float64" ? "Float64" : "Float32")
      when "//"
        return recv
      when "%", "remainder"
        return recv unless r_int && !a_int
      when "<=>"
        # Floats can be NaN.
        return r_int && a_int ? @table.named!("Int32") : @table.nilable(@table.named!("Int32"))
      end
      nil
    end

    private def number_name(t : TyId) : String?
      ty = @table[t]
      return nil unless ty.kind.named?
      n = map[ty.def_id.not_nil!].full_name
      INT_TYPES.includes?(n) || FLOAT_TYPES.includes?(n) ? n : nil
    end

    # Block argument types of `&.foo` blocks, set when entering them.
    @implicit_args = {} of HIR::ExprId => TyId

    # `xs.map(&.size)`: the receiver of `.size` is the block's argument.
    private def implicit_receiver(call : HIR::Expr) : TyId?
      return nil unless call.syntax.implicit_object_call? && call.receiver.nil?
      parent_id = @parent[call.id]? || return nil
      parent = @body.expr(parent_id)
      if parent.kind.when?
        # `case x; when .nil?`: the receiver is the subject.
        kase = @parent[parent_id]?.try { |k| @body.expr(k) } || return nil
        subj = kase.children[0]?
        return nil unless subj && !@body.expr(subj).kind.nop?
        return @types[subj]? || @table.unknown
      end
      return nil unless parent.syntax.implicit_object_call?
      @implicit_args[parent_id]? || @table.unknown
    end

    # Resolutions of calls, from the last evaluation of each call.
    getter resolutions = {} of HIR::ExprId => CallResolution

    # Union of the viable candidates' declared returns; unknown when any of
    # them has none.
    private def return_type_of(res : CallResolution, block_ret : TyId?) : TyId
      return @table.unknown if res.candidates.empty?
      results = res.candidates.map do |c|
        declared_return(c, block_ret) || return @table.unknown
      end
      union_or_unknown(results.uniq)
    end

    private def block_args(blk : HIR::Expr) : Array(HIR::BindingId)
      # The block expression lives in its own scope (see LowerBody#lower_block).
      return [] of HIR::BindingId unless own_scope?(blk)
      @body.bindings.select { |b| b.scope == blk.scope && b.kind.block_arg? }.map(&.id)
    end

    @resolver : CallResolver? = nil

    def resolver : CallResolver
      @resolver ||= CallResolver.new(@table)
    end

    # Overload resolution of a call expression with the argument types
    # inferred for it (operand types from the call's last evaluation).
    def resolve_call(call : HIR::Expr) : CallResolution
      name = call.name || return CallResolution.unresolved
      recv_t = call.receiver.try { |r| operand(r) } || implicit_receiver(call)
      receiver = recv_t || implicit_self(call)
      groups = method_groups(receiver, name)
      if groups.empty? && recv_t.nil?
        top = top_level_sites(name)
        groups = [{@table.unknown, top}] unless top.empty?
      end
      resolver.resolve(groups, call_site(call))
    end

    # Call shape with argument types from this inference.
    def call_site(call : HIR::Expr) : CallSite
      args = [] of CallArg
      dsplat = false
      named = [] of {String, CallArg}
      call.children.each do |c|
        a = @body.expr(c)
        case a.kind
        when .splat?
          # `*tuple`: its elements are the arguments; other splats hide
          # the count.
          st = a.children[0]?.try { |x| @table[operand(x)] }
          if st && st.kind.tuple?
            st.args.each { |t| args << CallArg.new(t) }
          else
            args << CallArg.new(@table.unknown, splat: true)
          end
        when .double_splat?
          st = a.children[0]?.try { |x| @table[operand(x)] }
          if st && st.kind.named_tuple?
            st.names.each_with_index { |n, i| named << {n, CallArg.new(st.args[i])} }
          else
            dsplat = true
          end
        else
          args << CallArg.new(operand(c), literal: a.kind.literal? ? a.syntax : nil)
        end
      end
      call.named_args.each do |(n, v)|
        a = @body.expr(v)
        named << {n, CallArg.new(operand(v), literal: a.kind.literal? ? a.syntax : nil)}
      end
      CallSite.new(args, named, dsplat, !call.block.nil?)
    end

    # Methods named *name* per receiver member type: instance methods for
    # instance types, `self.` methods (and `extend`ed modules) for
    # metaclasses. Unknown receivers have no groups.
    def method_groups(receiver_type : TyId, name : String) : Array({TyId, Array(MethodMatch)})
      without_redefined(method_groups_all(receiver_type, name))
    end

    # Drops defs that a later def with the same restrictions redefines in
    # the same type (reopened classes, `previous_def` chains): the
    # compiler keeps only the last one.
    private def without_redefined(groups : Array({TyId, Array(MethodMatch)})) : Array({TyId, Array(MethodMatch)})
      groups.map do |(self_t, ms)|
        kept = ms.reject do |m|
          ms.any? { |o| o != m && o.owner == m.owner && Infer.redefines?(o.site, m.site) }
        end
        {self_t, kept}
      end
    end

    # Does *later* redefine *earlier* (same owner type checked by caller)?
    # The compiler's key: positional restrictions (defaults ignored), the
    # splat/double-splat/block shape, and required named params.
    def self.redefines?(later : Semantics::Site, earlier : Semantics::Site) : Bool
      return false unless later.item.name == earlier.item.name && later.item.kind == earlier.item.kind
      ls = later.item.signature || return false
      es = earlier.item.signature || return false
      return false unless (ls.receiver.nil?) == (es.receiver.nil?)
      return false unless redef_key(ls) == redef_key(es)
      Infer.declared_after?(later, earlier)
    end

    # Positional params up to the first defaulted one (later defaulted
    # params can be omitted, so `f(x, y = 1)` redefines `f(x)`), the
    # splat/double-splat/block shape, and required named params.
    def self.redef_key(sig : Items::Signature) : Array(String)
      key = [] of String
      splat = sig.params.index(&.kind.splat?)
      defaulted = false
      sig.params.each_with_index do |p, i|
        case p.kind
        in .positional?
          if splat && i > splat
            key << "named:#{p.call_name}:#{p.restriction}" if p.default.nil?
          elsif p.default
            defaulted = true
          elsif !defaulted
            key << "pos:#{p.restriction}"
          end
        in .splat?        then key << "*#{p.name ? "" : "marker"}:#{p.restriction}"
        in .double_splat? then key << "**"
        in .block?        then key << "&"
        end
      end
      key
    end

    # Source order within a file; across files the DefMap's file order
    # (which follows the require closure only approximately).
    def self.declared_after?(a : Semantics::Site, b : Semantics::Site) : Bool
      a.file == b.file ? a.item.range.start > b.item.range.start : a.file.value > b.file.value
    end

    private def method_groups_all(receiver_type : TyId, name : String) : Array({TyId, Array(MethodMatch)})
      groups = [] of {TyId, Array(MethodMatch)}
      @table.members(receiver_type).each do |member|
        t = @table[member]
        ms = [] of MethodMatch
        case t.kind
        when .named?
          def_id = t.def_id.not_nil!
          bindings = generic_bindings(def_id, t.args)
          map.lookup_member(def_id, name).each do |site|
            next unless site.item.kind.def? || site.item.kind.macro?
            ms << MethodMatch.new(site, owner_of(def_id, site), bindings)
          end
        when .metaclass?
          inst = @table[t.args[0]]
          next unless inst.kind.named?
          def_id = inst.def_id.not_nil!
          bindings = generic_bindings(def_id, inst.args)
          sites = map.lookup_member(def_id, "self.#{name}")
          map.extends(def_id).each { |ext| sites += map.lookup_member(ext, name) }
          sites.each do |site|
            next unless site.item.kind.def? || site.item.kind.macro?
            ms << MethodMatch.new(site, owner_of(def_id, site), bindings)
          end
          # A type is also a `Class` instance (`Foo.name`, `Foo.class`).
          if ms.empty? && (cls = map.lookup_path("::Class"))
            map.lookup_member(cls, name).each do |site|
              next unless site.item.kind.def? || site.item.kind.macro?
              ms << MethodMatch.new(site, owner_of(cls, site), {} of String => TyId)
            end
            unless ms.empty?
              groups << {member, ms}
              next
            end
          end
        end
        groups << {self_for(member), ms} unless ms.empty?
      end
      groups
    end

    def top_level_sites(name : String) : Array(MethodMatch)
      sites = map.program.members[name]? || return [] of MethodMatch
      sites.select { |s| s.item.kind.def? || s.item.kind.macro? }
        .map { |s| MethodMatch.new(s, Semantics::DefMap::PROGRAM, {} of String => TyId) }
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

    # Block arg types from `& : T, U -> R` / `&block : T -> R` restrictions,
    # else from the `yield`s in the method body (shallow summary).
    private def block_types_for(cands : Array(CallCandidate), block_ret : TyId? = nil) : Array(TyId)
      cands.each do |c|
        m = c.match
        sig = m.site.item.signature || next
        bp = sig.params.find(&.kind.block?)
        r = bp.try(&.restriction)
        unless r
          ts = yield_summary(m, c.self_type, c, block_ret)
          return ts unless ts.empty?
          next
        end
        owner = map[m.owner]
        t = TypeExprParser.parse(r, @table, m.owner, owner.type_params + sig.free_vars, c.self_type)
        pt = @table[t]
        next unless pt.kind.proc?
        # Unbound `forall` vars stay open (`U` of `each_with_object` without
        # an argument type); the owner's own params (`T` inside Array) are
        # meaningful there.
        bindings = arg_bindings(c)
        return pt.args[0...-1].map do |a|
          x = Subst.apply(@table, a, bindings)
          # Keep open vars inside generic code (`forall U` callers can still
          # read `U`); only the def's own unbound vars become unknown when
          # the caller has no type params of that name.
          sig.free_vars.any? { |fv| mentions_param?(x, fv) && !@ctx.type_params.includes?(fv) } ? @table.unknown : x
        end
      end
      [] of TyId
    end

    private def mentions_param?(t : TyId, name : String) : Bool
      ty = @table[t]
      return ty.param == name if ty.kind.type_param?
      ty.args.any? { |x| mentions_param?(x, name) }
    end

    # Receiver bindings plus `forall` vars bound from the restrictions of
    # the parameters the arguments went to.
    private def arg_bindings(c : CallCandidate) : Hash(String, TyId)
      m = c.match
      bindings = m.bindings.dup
      sig = m.site.item.signature || return bindings
      return bindings if sig.free_vars.empty?
      owner = map[m.owner]
      tparams = owner.type_params + sig.free_vars
      (c.arg_params + c.named_params).each_with_index do |pi, i|
        next unless pi && (r = sig.params[pi].restriction) && (a = c.arg_types[i]?)
        next if sig.params[pi].kind.double_splat?
        Subst.unify(@table, TypeExprParser.parse(r, @table, m.owner, tparams, c.self_type), a, bindings)
      end
      bindings
    end

    # Return type of one candidate, with generic and `forall` substitution.
    private def declared_return(c : CallCandidate, block_ret : TyId?) : TyId?
      m = c.match
      item = m.site.item
      sig = item.signature || return nil
      owner = map[m.owner]
      self_t = c.self_type
      text = sig.return_type
      if text.nil? && sig.is_abstract
        # Virtual dispatch (decision 1): an abstract def without a return
        # type returns what its implementations in concrete subtypes do.
        return virtual_return(c, block_ret)
      end
      if text.nil?
        # `getter x = [] of T`: the type of the ivar the macro declares.
        if item.origin.macro? && sig.params.empty? && item.name[0].letter?
          ivar = (sig.receiver ? "@@" : "@") + item.name.rstrip("?!")
          t = Infer.ivar_type(map, @table, m.owner, ivar, !sig.receiver.nil?, @ctx)
          return Subst.apply(@table, t, m.bindings) unless @table.unknown?(t)
        end
        # `def initialize` via `self.new`.
        return self_t if item.name == "new"
        # Compiler primitives have empty bodies: their type is known here
        # or not at all (an empty body would summarise as Nil).
        if prim = primitive_name(item)
          return primitive_return(prim, c)
        end
        # Unannotated def: summary of its body for this call shape.
        t = summary(c, block_ret).returns
        return t if t == @table.no_return || t == @table.pending
        return nil if @table.unknown?(t)
        r = Subst.apply(@table, t, free_var_bindings(c, block_ret))
        return still_open?(r) ? nil : r
      end
      tparams = owner.type_params + sig.free_vars
      ret = TypeExprParser.parse(text, @table, m.owner, tparams, self_t)
      result = Subst.apply(@table, ret, free_var_bindings(c, block_ret))
      still_open?(result) ? nil : result
    end

    # `:pointer_malloc` of `@[Primitive(:pointer_malloc)]`.
    private def primitive_name(item : Items::Item) : String?
      item.annotations.each do |a|
        if m = a.match(/\A:{0,2}Primitive\(:(\w+)/)
          return m[1]
        end
      end
      nil
    end

    # Types of the primitives declared without a return type (the others
    # use their declared one).
    private def primitive_return(prim : String, c : CallCandidate) : TyId?
      self_t = c.self_type
      case prim
      when "class"
        # Per receiver member: `(Int32 | String).class` is a union of
        # metaclasses; `self_type` is one member already. A metaclass's
        # class is `Class`.
        st = @table[self_t]
        return nil if st.kind.unknown?
        st.kind.metaclass? ? @table.named?("Class") : @table.metaclass(self_t)
      when "pointer_malloc", "pointer_new"
        self_t
      end
    end

    MAX_VIRTUAL = 8

    # Join of the returns of an abstract def's implementations in the
    # descendants of the receiver type (at most MAX_VIRTUAL of them).
    private def virtual_return(c : CallCandidate, block_ret : TyId?) : TyId?
      recv = @table[c.self_type]
      return nil unless recv.kind.named?
      name = c.match.site.item.name
      key = c.match.site.item.signature.try(&.receiver) ? "self.#{name}" : name
      impls = [] of TyId
      map.descendants(recv.def_id.not_nil!).each do |d|
        info = map[d]
        sites = info.members[key]? || next
        site = sites.find { |s| s.item.kind.def? && !s.item.signature.try(&.is_abstract) } || next
        sub = @table.named(d, info.type_params.map { |p| @table.type_param(p) })
        cand = resolver.bind(MethodMatch.new(site, d, generic_bindings(d, [] of TyId)), sub,
          CallSite.new(c.arg_types[0, c.arg_params.size].map { |t| CallArg.new(t) }, [] of {String, CallArg}, false, !block_ret.nil?)) || next
        t = declared_return(cand, block_ret) || return nil
        impls << t
        return nil if impls.size > MAX_VIRTUAL
      end
      impls.empty? ? nil : union_or_unknown(impls.uniq)
    end

    # Receiver and argument bindings, plus `forall` vars bound from the
    # block's value (`& : T -> U`).
    private def free_var_bindings(c : CallCandidate, block_ret : TyId?) : Hash(String, TyId)
      bindings = arg_bindings(c)
      m = c.match
      sig = m.site.item.signature || return bindings
      return bindings if sig.free_vars.empty? || block_ret.nil?
      bp = sig.params.find(&.kind.block?) || return bindings
      r = bp.restriction || return bindings
      owner = map[m.owner]
      pt = TypeExprParser.parse(r, @table, m.owner, owner.type_params + sig.free_vars, c.self_type)
      if @table[pt].kind.proc?
        Subst.unify(@table, @table[pt].args.last, block_ret, bindings)
      end
      bindings
    end

    # A type param left after substitution that is not one of the current
    # body's own type params (`T` inside `Array(T)` code is meaningful;
    # an unbound `U` from a callee's `forall` is not).
    private def still_open?(t : TyId) : Bool
      ty = @table[t]
      return !@ctx.type_params.includes?(ty.param.not_nil!) if ty.kind.type_param?
      ty.args.any? { |x| still_open?(x) }
    end

    # `self` in a method's signature: the receiver instance type.
    private def self_for(receiver_type : TyId) : TyId
      t = @table[receiver_type]
      t.kind.metaclass? ? t.args[0] : receiver_type
    end

    # Summary of a candidate's body for this call: params without a
    # restriction take the argument types bound to them.
    # *for_yields*: the caller wants the yield (block argument) types,
    # which depend on the argument types more than on the block value.
    private def summary(c : CallCandidate, block_ret : TyId? = nil, for_yields = false) : Summaries::Summary
      cache = @summaries || return Summaries::Summary.new(@table.unknown, [] of TyId)
      loader = @source_loader || return cache.unknown_summary
      m = c.match
      sig = m.site.item.signature
      return cache.unknown_summary if sig.try(&.is_abstract)
      args = [] of TyId
      defaults = [] of TyId
      if sig
        args = Array(TyId).new(sig.params.size, @table.unknown)
        defaults = Array(TyId).new(sig.params.size, @table.unknown)
        bound = Set(Int32).new
        (c.arg_params + c.named_params).each_with_index do |pi, i|
          next unless pi
          bound << pi
          next unless t = c.arg_types[i]?
          next unless sig.params[pi].kind.positional?
          # Restricted params also take the argument type: the compiler
          # instantiates the def for it (`other : Int::Primitive` with an
          # Int32 argument is an Int32 inside), when it definitely fits.
          if sig.params[pi].restriction
            next if @table.unknown?(t)
            rt = resolver.restriction(c, pi) || next
            # Without autocasting: `x : Int64` called with an Int32 is an
            # Int64 inside.
            next unless resolver.matches_exactly(t, rt).compatible?
          end
          args[pi] = t
        end
        # `*xs` / `**opts`: the tuple of the arguments they collect (only
        # when the call's shape is known: no splatted arguments).
        splat_param_types(c, sig).each { |pi, t| args[pi] = t }
        # Omitted params with a literal default (`if_none = nil`): the
        # default's type.
        sig.params.each_with_index do |p, i|
          next if bound.includes?(i) || !p.kind.positional? || p.restriction
          d = p.default || next
          dt = Infer.value_text_type(d, @table, m.owner)
          next if @table.unknown?(dt)
          args[i] = dt
          defaults[i] = dt
        end
      end
      # The block's value is part of the call shape (`reduce`'s memo). Over
      # the shape cap, yield types fall back to the argument types alone;
      # return types keep the block value (and literal defaults) instead,
      # since without it `yield` is Pending and `if v; yield v; end` would
      # summarise to Nil.
      known_block = block_ret && !@table.unknown?(block_ret) ? block_ret : nil
      shape = known_block ? args + [known_block] : args
      fallback = known_block ? (for_yields ? args : defaults + [known_block]) : nil
      cache.get(m.site, c.self_type, shape, fallback: fallback) do |eff_args|
        node = loader.call(m.site) || next nil
        owner = map[m.owner]
        # Type params the receiver carries from the caller (`Pointer(UC)`
        # inside a `forall UC` def) are meaningful in the callee too.
        tparams = owner.type_params + (sig.try(&.free_vars) || [] of String)
        param_names(c.self_type, tparams)
        # `def self.x` bodies run on the metaclass (`self.new`, sibling
        # class methods); `c.self_type` is the instance for signatures.
        body_self = sig.try(&.receiver) && !@table.unknown?(c.self_type) ? @table.metaclass(c.self_type) : c.self_type
        ctx = DefContext.new(m.owner, body_self, tparams)
        inner = Infer.new(HIR::LowerBody.lower(node), ctx, @table)
        inner.source_loader = loader
        inner.summaries = cache
        inner.summary_depth = summary_depth
        inner.summarising = true
        inner.current_def = m.site
        n = sig.try(&.params.size) || 0
        inner.param_args = positional_param_args(sig, eff_args.size > n ? eff_args[0, n] : eff_args)
        inner.yield_value = eff_args[n]? if eff_args.size > n
        inner.with_source(node.tree.text).run
        yields = inner.yield_types.map { |ts| union_or_unknown(ts.uniq) }
        Summaries::Summary.new(inner.opaque_macros? ? @table.unknown : inner.return_type, yields, inner.with_self)
      end
    end

    # Types of a candidate's `*splat` (Tuple of its arguments) and
    # `**double_splat` (NamedTuple of the extra named arguments) params.
    private def splat_param_types(c : CallCandidate, sig : Items::Signature) : Hash(Int32, TyId)
      result = {} of Int32 => TyId
      return result unless c.structural.compatible?
      sig.params.each_with_index do |p, pi|
        next unless p.name
        case p.kind
        when .splat?
          elems = c.arg_params.each_with_index.select { |(x, _)| x == pi }.map { |(_, i)| c.arg_types[i] }.to_a
          result[pi] = @table.tuple(elems)
        when .double_splat?
          names = [] of String
          types = [] of TyId
          site_named = c.named_params
          site_named.each_with_index do |x, i|
            next unless x == pi
            names << (c.named_names[i]? || "?")
            types << c.arg_types[c.arg_params.size + i]
          end
          result[pi] = @table.named_tuple(names, types)
        end
      end
      result
    end

    # Adds the type param names mentioned in *t* to *names*.
    private def param_names(t : TyId, names : Array(String), depth = 0) : Nil
      return if depth > 8
      ty = @table[t]
      if ty.kind.type_param?
        names << ty.param.not_nil! unless names.includes?(ty.param.not_nil!)
      else
        ty.args.each { |a| param_names(a, names, depth + 1) }
      end
    end

    # Signature-indexed args → order of param bindings in the body (block
    # params are bindings too; `*`/`**` markers without names are not).
    private def positional_param_args(sig : Items::Signature?, args : Array(TyId)) : Array(TyId)
      return [] of TyId unless sig
      result = [] of TyId
      sig.params.each_with_index do |p, i|
        next if p.name.nil? # bare `*` / `&`
        result << (args[i]? || @table.unknown)
      end
      result
    end

    # Joined types of each `yield` argument in the candidate's body, with
    # the receiver's generic bindings.
    private def yield_summary(m : MethodMatch, receiver_type : TyId, c : CallCandidate? = nil, block_ret : TyId? = nil) : Array(TyId)
      return [] of TyId if summary_depth <= 0
      cand = c || return [] of TyId
      summary(cand, block_ret, for_yields: true).yields.map do |t|
        r = Subst.apply(@table, t, m.bindings)
        still_open?(r) ? @table.unknown : r
      end
    end

    # Return type of `recv.name(args)` (used by op-assign).
    private def call_return(recv : TyId, name : String, args : Array(TyId), block_ret : TyId?) : TyId?
      return nil if @table.unknown?(recv)
      site = CallSite.new(args.map { |a| CallArg.new(a) }, [] of {String, CallArg}, false, false)
      t = return_type_of(resolver.resolve(method_groups(recv, name), site), block_ret)
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
