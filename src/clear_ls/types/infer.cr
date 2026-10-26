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
      solve(@env.dup)
      @main_pass = false
      @reached = @in.keys.to_set
      solve_dead
      final_binding_types
      self
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
           when .while?, .until? then nil_t
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
             ts.each_with_index do |t, i|
               (@yield_types[i]? || (@yield_types << [] of TyId; @yield_types[i])) << t
             end
             # Value of the caller's block, when the summary was asked for
             # one call site; otherwise NoReturn: the block's value is not
             # known yet and contributes nothing (`Pending` seed), so
             # `memo = yield memo, e` keeps memo's other assignments.
             @yield_value || (@summarising ? @table.pending : @table.unknown)
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

    # Namespace lookup for code outside defs (`class Foo; self.x; end`),
    # set by the caller; nil inside defs.
    property type_body_self : Proc(UInt32, TyId?)? = nil

    private def self_at(e : HIR::Expr) : TyId
      @type_body_self.try(&.call(e.range.start)) || @ctx.self_type
    end

    # Implicit receiver: `self` at the call site.
    private def implicit_self(e : HIR::Expr) : TyId
      self_at(e)
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
      elems = e.children.map { |c| operand(c) }
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
      n = e.target_count
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
             call_return(current, op, [vt], nil) || primitive_op(current, op, [vt]) || current
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

    # Block arg types for a call's block.
    private def closure_param_types(call : HIR::Expr) : Array(TyId)
      name = call.name || return [] of TyId
      recv_t = call.receiver.try { |r| operand(r) }
      return [] of TyId if name.in?("as", "as?")
      return [@table.without_nil(recv_t)] if name == "try" && recv_t
      # The block's value from the previous closure iteration feeds yield
      # summaries whose arguments depend on it (`reduce(memo) { |acc, x| }`).
      block_ret = call.block.try { |b| @types[b]? }
      block_types_for(resolve_call(call).candidates, block_ret)
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


      # `Enumerable.element_type(x)` / `Iterator.element_type(x)`: what x
      # yields from `each` (generic arg of Enumerable/Iterator ancestors).
      if name == "element_type" && args.size == 1 && recv_t && @table[recv_t].kind.metaclass?
        if (et = enumerable_element(args[0])) && !@table.unknown?(et)
          return et
        end
      end

      if name == "try" && recv_t && e.block
        # `x.try { |v| ... }`: v is x without Nil; result is block value or Nil.
        inner = block_ret || @table.unknown
        return @table.unknown?(inner) ? inner : @table.nilable(inner)
      end

      recv_t ||= implicit_receiver(e)
      receiver_type = recv_t || implicit_self(e)
      if name == "value" && args.empty? && (rt = @table[receiver_type]).kind.named? && map[rt.def_id.not_nil!].kind.enum?
        return enum_base(rt.def_id.not_nil!)
      end
      res = resolve_call(e)
      if name == "new" && res.candidates.empty?
        # `Foo.new` without an explicit `self.new`: instance of Foo.
        rt = @table[receiver_type]
        return rt.args[0] if rt.kind.metaclass?
      end
      @resolutions[e.id] = res
      if res.candidates.empty? && (prim = primitive_op(receiver_type, name, args))
        return prim
      end
      if res.candidates.empty? && (gen = generated_method(receiver_type, name, args))
        return gen
      end
      declared = return_type_of(res, block_ret)
      # Contracts only fill in what resolution could not type, and only
      # for stdlib owners (user code overriding `sum` keeps its type).
      if partially_unknown?(declared) && stdlib_candidates?(res) && (c = contract(e, receiver_type, name, args, block_ret))
        return c
      end
      declared
    end

    # Methods the compiler defines without source: `Proc#call`, enum
    # member predicates (`Color::Red` → `#red?`).
    private def generated_method(recv : TyId, name : String, args : Array(TyId)) : TyId?
      t = @table[recv]
      if t.kind.proc? && name == "call"
        return t.args.last
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
      return args[0] if name == "/" && !r_int && !a_int && rn == an
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
      call.children.each do |c|
        a = @body.expr(c)
        case a.kind
        when .splat?        then args << CallArg.new(@table.unknown, splat: true)
        when .double_splat? then dsplat = true
        else
          args << CallArg.new(operand(c), literal: a.kind.literal? ? a.syntax : nil)
        end
      end
      named = call.named_args.map do |(n, v)|
        a = @body.expr(v)
        {n, CallArg.new(operand(v), literal: a.kind.literal? ? a.syntax : nil)}
      end
      CallSite.new(args, named, dsplat, !call.block.nil?)
    end

    # Methods named *name* per receiver member type: instance methods for
    # instance types, `self.` methods (and `extend`ed modules) for
    # metaclasses. Unknown receivers have no groups.
    def method_groups(receiver_type : TyId, name : String) : Array({TyId, Array(MethodMatch)})
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
      if text.nil?
        # `getter x = [] of T`: the type of the ivar the macro declares.
        if item.origin.macro? && sig.params.empty? && item.name[0].letter?
          ivar = (sig.receiver ? "@@" : "@") + item.name.rstrip("?!")
          t = Infer.ivar_type(map, @table, m.owner, ivar, !sig.receiver.nil?, @ctx)
          return Subst.apply(@table, t, m.bindings) unless @table.unknown?(t)
        end
        # `def initialize` via `self.new`.
        return self_t if item.name == "new"
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
    private def summary(c : CallCandidate, block_ret : TyId? = nil) : Summaries::Summary
      cache = @summaries || return Summaries::Summary.new(@table.unknown, [] of TyId)
      loader = @source_loader || return cache.unknown_summary
      m = c.match
      sig = m.site.item.signature
      return cache.unknown_summary if sig.try(&.is_abstract)
      args = [] of TyId
      if sig
        args = Array(TyId).new(sig.params.size, @table.unknown)
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
        # Omitted params with a literal default (`if_none = nil`): the
        # default's type.
        sig.params.each_with_index do |p, i|
          next if bound.includes?(i) || !p.kind.positional? || p.restriction
          d = p.default || next
          dt = Infer.value_text_type(d, @table, m.owner)
          args[i] = dt unless @table.unknown?(dt)
        end
      end
      # The block's value is part of the call shape (`reduce`'s memo).
      shape = block_ret && !@table.unknown?(block_ret) ? args + [block_ret] : args
      cache.get(m.site, c.self_type, shape) do |eff_args|
        node = loader.call(m.site) || next nil
        owner = map[m.owner]
        # Type params the receiver carries from the caller (`Pointer(UC)`
        # inside a `forall UC` def) are meaningful in the callee too.
        tparams = owner.type_params + (sig.try(&.free_vars) || [] of String)
        param_names(c.self_type, tparams)
        ctx = DefContext.new(m.owner, c.self_type, tparams)
        inner = Infer.new(HIR::LowerBody.lower(node), ctx, @table)
        inner.source_loader = loader
        inner.summaries = cache
        inner.summary_depth = summary_depth
        inner.summarising = true
        n = sig.try(&.params.size) || 0
        inner.param_args = positional_param_args(sig, eff_args.size > n ? eff_args[0, n] : eff_args)
        inner.yield_value = eff_args[n]? if eff_args.size > n
        inner.with_source(node.tree.text).run
        yields = inner.yield_types.map { |ts| union_or_unknown(ts.uniq) }
        Summaries::Summary.new(inner.return_type, yields)
      end
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
      summary(cand, block_ret).yields.map do |t|
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
