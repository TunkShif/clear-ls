require "./cfg"

module ClearLS::Flow
  # Builds a `CFG` from a lowered body.
  #
  # Every expression gets an `Eval` operation in evaluation order (operands
  # first), so a transfer function can read operand types instead of
  # recursing. Control constructs become blocks and edges:
  #
  # - `if`/`unless`/ternary: conditions are split on `&&`, `||`, `!` into
  #   branch chains; the join evaluates the `if` from its branch values.
  # - `case`: one test per `when` condition; `case/in` without a match is
  #   unreachable, `case/when` without `else` yields Nil.
  # - `while`/`until`: loop head with the condition; `break` → after,
  #   `next` → head.
  # - call blocks and proc literals: closure bodies that run 0..n times,
  #   `Enter` binds their parameters at each iteration; `next` contributes
  #   to the block's value, `break` leaves the call, `return` leaves the def
  #   (or the proc literal).
  # - `begin`/`rescue`/`else`/`ensure`: blocks inside the body have the
  #   rescue dispatch block as `handler`; `ensure` is analysed on normal
  #   paths only (exceptional and jump paths skip it).
  # - code after `return`/`break`/`next` lands in a block without
  #   predecessors whose `fallback` is the block it followed.
  class Builder
    def self.build(body : HIR::Body) : CFG
      new(body).run
    end

    # Targets for jumps inside a loop or closure body.
    private record LoopCtx, break_to : BlockId, next_to : BlockId, value_owner : HIR::ExprId?, proc : Bool

    @blocks = [] of Block
    @merges = {} of HIR::ExprId => Array(Source)
    @loops = [] of LoopCtx
    @handlers = [] of BlockId
    @eval_block = {} of HIR::ExprId => BlockId
    @closure_owner = {} of HIR::ExprId => HIR::ExprId
    @returns = [] of Source
    @cur = CFG::ENTRY

    def initialize(@body : HIR::Body)
      @blocks << Block.new(CFG::ENTRY)
      @blocks << Block.new(CFG::EXIT)
      @blocks[1].terminator = Terminator::Exit
    end

    def run : CFG
      lower(@body.root)
      # The def's value: the body's last expression, joined with every
      # `return` (sources under `CFG#returns`).
      @returns << Source.new(@cur, @body.root)
      finish(Terminator::Return, [CFG::EXIT])
      @blocks.each { |b| b.handler.try { |h| block(h).exc_preds << b.id } }
      CFG.new(@blocks, @merges, @eval_block, @closure_owner, @returns)
    end

    # -- block plumbing -----------------------------------------------------------

    private def new_block : BlockId
      id = BlockId.new(@blocks.size)
      b = Block.new(id)
      b.handler = @handlers.last?
      @blocks << b
      id
    end

    private def block(id : BlockId) : Block
      @blocks[id.value]
    end

    private def edge(from : BlockId, to : BlockId) : Nil
      block(from).succs << to
      block(to).preds << from
    end

    private def finish(term : Terminator, targets : Array(BlockId), test : Test? = nil) : Nil
      b = block(@cur)
      b.terminator = term
      b.test = test
      targets.each { |t| edge(@cur, t) }
    end

    private def goto(*targets : BlockId) : Nil
      finish(Terminator::Goto, targets.to_a)
    end

    # Continues in an unreachable block after a jump.
    private def start_dead : Nil
      prev = @cur
      @cur = new_block
      block(@cur).fallback = prev
    end

    private def emit(kind : OpKind, id : HIR::ExprId) : Nil
      block(@cur).ops << Op.new(kind, id)
      @eval_block[id] = @cur if kind.eval?
    end

    private def eval(id : HIR::ExprId) : Nil
      emit(OpKind::Eval, id)
    end

    private def add_source(owner : HIR::ExprId, src : Source) : Nil
      (@merges[owner] ||= [] of Source) << src
    end

    # -- expressions ----------------------------------------------------------------

    private def lower(id : HIR::ExprId) : Nil
      e = @body.expr(id)
      case e.kind
      when .if?, .unless?
        return lower_generic(e) unless e.children.size == 3
        lower_if(e)
      when .case?
        lower_case(e)
      when .while?, .until?
        lower_while(e)
      when .and?, .or?
        return lower_generic(e) unless e.children.size == 2
        lower_and_or(e)
      when .begin?
        lower_begin(e)
      when .return?, .break?, .next?
        lower_jump(e)
      when .proc_literal?
        if blk = e.children[0]?
          lower_closure(blk, e)
        end
        eval(id)
      when .assign?, .multi_assign?
        n = e.target_count
        e.children[n..].each { |v| lower(v) }
        # Local targets are writes, not reads; other targets (`@x`, `a.b`,
        # `a[i]`) evaluate their operands.
        e.children[0, n].each { |t| lower(t) unless @body.expr(t).kind.local_ref? }
        eval(id)
      when .op_assign?
        target, value = e.children[0]?, e.children[1]?
        value.try { |v| lower(v) }
        lower(target) if target && !@body.expr(target).kind.local_ref?
        eval(id)
      else
        lower_generic(e)
      end
    end

    private def lower_generic(e : HIR::Expr) : Nil
      e.receiver.try { |r| lower(r) }
      e.children.each { |c| lower(c) }
      e.named_args.each { |(_, v)| lower(v) }
      e.block.try do |b|
        if @body.expr(b).syntax.block_argument?
          # `&proc`: an argument value, evaluated once.
          lower_generic(@body.expr(b))
        else
          lower_closure(b, e)
        end
      end
      eval(e.id)
    end

    # Branches to *t* when *id* is truthy, else to *f*. Short-circuit
    # operators and `!` become branch chains so each edge carries the facts
    # of one atomic test.
    private def lower_cond(id : HIR::ExprId, t : BlockId, f : BlockId) : Nil
      e = @body.expr(id)
      if (e.kind.and? || e.kind.or?) && e.children.size == 2
        mid = new_block
        if e.kind.and?
          lower_cond(e.children[0], mid, f)
        else
          lower_cond(e.children[0], t, mid)
        end
        @cur = mid
        lower_cond(e.children[1], t, f)
      elsif e.kind.not? && e.children.size == 1
        lower_cond(e.children[0], f, t)
      else
        lower(id)
        finish(Terminator::Branch, [t, f], Test.new(TestKind::Truthy, id))
      end
    end

    private def lower_if(e : HIR::Expr) : Nil
      cond, then_b, else_b = e.children[0], e.children[1], e.children[2]
      t = new_block
      f = new_block
      e.kind.unless? ? lower_cond(cond, f, t) : lower_cond(cond, t, f)
      @cur = t
      lower(then_b)
      then_end = @cur
      @cur = f
      lower(else_b)
      else_end = @cur
      join = new_block
      @cur = then_end
      goto(join)
      @cur = else_end
      goto(join)
      @cur = join
      add_source(e.id, Source.new(then_end, then_b))
      add_source(e.id, Source.new(else_end, else_b))
      eval(e.id)
    end

    private def lower_case(e : HIR::Expr) : Nil
      subject = e.children[0]?
      subject = nil if subject && @body.expr(subject).kind.nop?
      subject.try { |s| lower(s) }
      ends = [] of {BlockId, HIR::ExprId?}
      exhaustive = false
      else_clause = nil
      e.children[1..]?.try &.each do |c|
        clause = @body.expr(c)
        unless clause.kind.when?
          else_clause = c
          next
        end
        exhaustive = true if clause.syntax.in?
        conds = clause.children[0...-1]
        value = clause.children.last
        entry = new_block
        if conds.empty?
          goto(entry)
          @cur = new_block
          block(@cur).fallback = entry
        end
        conds.each do |cond|
          lower(cond)
          test = subject ? Test.new(TestKind::CaseWhen, cond, subject) : Test.new(TestKind::Truthy, cond)
          miss = new_block
          finish(Terminator::Branch, [entry, miss], test)
          @cur = miss
        end
        miss = @cur
        @cur = entry
        lower(value)
        ends << {@cur, value}
        @cur = miss
      end
      if ec = else_clause
        lower(ec)
        ends << {@cur, ec}
      elsif exhaustive
        finish(Terminator::Unreachable, [] of BlockId)
      else
        ends << {@cur, nil}
      end
      join = new_block
      ends.each do |(b, v)|
        @cur = b
        goto(join)
        add_source(e.id, Source.new(b, v))
      end
      @merges[e.id] ||= [] of Source
      @cur = join
      eval(e.id)
    end

    private def lower_while(e : HIR::Expr) : Nil
      cond, body = e.children[0]?, e.children[1]?
      head = new_block
      goto(head)
      @cur = head
      body_b = new_block
      after = new_block
      if cond
        e.kind.until? ? lower_cond(cond, after, body_b) : lower_cond(cond, body_b, after)
      else
        goto(body_b, after)
      end
      @loops << LoopCtx.new(after, head, nil, false)
      @cur = body_b
      body.try { |b| lower(b) }
      goto(head)
      @loops.pop
      @cur = after
      eval(e.id)
    end

    # `a && b` / `a || b` as a value: the value is the falsy (truthy) part
    # of `a`, or `b`.
    private def lower_and_or(e : HIR::Expr) : Nil
      a, b = e.children[0], e.children[1]
      lower(a)
      a_end = @cur
      rhs = new_block
      join = new_block
      test = Test.new(TestKind::Truthy, a)
      if e.kind.and?
        finish(Terminator::Branch, [rhs, join], test)
      else
        finish(Terminator::Branch, [join, rhs], test)
      end
      @cur = rhs
      lower(b)
      b_end = @cur
      goto(join)
      @cur = join
      add_source(e.id, Source.new(a_end, a, e.kind.and? ? Filter::Falsy : Filter::Truthy))
      add_source(e.id, Source.new(b_end, b))
      eval(e.id)
    end

    private def lower_jump(e : HIR::Expr) : Nil
      e.children.each { |c| lower(c) }
      eval(e.id)
      # Value: the single argument; several (`return a, b`) form a tuple,
      # recorded as the jump itself (typed by `Infer#jump_value`).
      value = e.children.size > 1 ? e.id : e.children.first?
      ctx = @loops.last?
      case e.kind
      when .return?
        if p = @loops.reverse_each.find(&.proc)
          # `return` in a proc literal returns from the proc.
          p.value_owner.try { |o| add_source(o, Source.new(@cur, value)) }
          goto(p.next_to)
        else
          # `return` without a value returns nil (Source with no expr).
          @returns << Source.new(@cur, value)
          finish(Terminator::Return, [CFG::EXIT])
        end
      when .break?
        goto(ctx ? ctx.break_to : CFG::EXIT)
      else # next
        if ctx
          ctx.value_owner.try { |o| add_source(o, Source.new(@cur, value)) }
          goto(ctx.next_to)
        else
          goto(CFG::EXIT)
        end
      end
      start_dead
    end

    # Body of a call's block or a proc literal. Runs 0..n times:
    #
    #   pre → head(Enter) → body → done(Eval block) → head | after
    #   pre → after
    private def lower_closure(blk_id : HIR::ExprId, owner : HIR::Expr) : Nil
      blk = @body.expr(blk_id)
      @closure_owner[blk_id] = owner.id
      head = new_block
      after = new_block
      done = new_block
      goto(head, after)
      @cur = head
      emit(OpKind::Enter, blk_id)
      @loops << LoopCtx.new(after, done, blk_id, owner.kind.proc_literal?)
      blk.children.each { |c| lower(c) }
      add_source(blk_id, Source.new(@cur, blk.children.last?))
      goto(done)
      @loops.pop
      @cur = done
      eval(blk_id)
      goto(head, after)
      @cur = after
    end

    # Children: body, Rescue clauses, else Seq, ensure Seq (see LowerBody).
    private def lower_begin(e : HIR::Expr) : Nil
      body = e.children[0]? || return eval(e.id)
      rest = e.children[1..]
      rescues = rest.select { |c| @body.expr(c).kind.rescue? }
      else_c = rest.find { |c| @body.expr(c).syntax.else? }
      ensure_c = rest.find { |c| @body.expr(c).syntax.ensure? }

      dispatch = nil
      unless rescues.empty?
        dispatch = new_block
        @handlers << dispatch
      end
      entry = new_block
      goto(entry)
      @cur = entry
      lower(body)
      @handlers.pop if dispatch
      value = body
      if ec = else_c
        # `else` runs outside the rescue's protection.
        nb = new_block
        goto(nb)
        @cur = nb
        lower(ec)
        value = ec
      end
      ends = [{@cur, value.as(HIR::ExprId?)}]
      if d = dispatch
        block(d).terminator = Terminator::Goto
        rescues.each do |r|
          clause = new_block
          edge(d, clause)
          @cur = clause
          emit(OpKind::Enter, r)
          rb = @body.expr(r).children[0]?
          rb.try { |x| lower(x) }
          ends << {@cur, rb}
        end
      end
      join = new_block
      ends.each do |(b, v)|
        @cur = b
        goto(join)
        add_source(e.id, Source.new(b, v))
      end
      @cur = join
      ensure_c.try { |x| lower(x) }
      eval(e.id)
    end
  end
end
