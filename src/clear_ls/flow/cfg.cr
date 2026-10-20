require "../hir"

module ClearLS::Flow
  record BlockId, value : Int32

  enum OpKind
    # Computes the expression's value; its operands were evaluated by
    # earlier operations.
    Eval
    # Before a closure body or rescue clause runs: binds block params of a
    # call or proc literal, or the rescue variable of a `Rescue` clause.
    Enter
  end

  record Op, kind : OpKind, expr : HIR::ExprId

  enum TestKind
    Truthy   # `cond` is truthy
    CaseWhen # `when cond` matches `subject` (`cond === subject`)
  end

  # Condition of a `Branch` terminator. Edge refinements derive from it.
  record Test, kind : TestKind, cond : HIR::ExprId, subject : HIR::ExprId? = nil

  enum Terminator
    Goto        # any successor may follow
    Branch      # successors are [true, false] for `test`
    Return      # successor is the exit block
    Unreachable # no successor (`case/in` without a match)
    Exit
  end

  # How a source's value contributes to a join (`a && b` takes the falsy
  # part of `a`, `a || b` the truthy part).
  enum Filter
    None
    Truthy
    Falsy
  end

  # One incoming value of a join expression: the value of `expr` (Nil when
  # absent) if `block`'s end is reachable.
  record Source, block : BlockId, expr : HIR::ExprId?, filter : Filter = Filter::None

  class Block
    getter id : BlockId
    getter ops = [] of Op
    getter succs = [] of BlockId
    getter preds = [] of BlockId
    property terminator : Terminator? = nil
    property test : Test? = nil
    # Rescue dispatch block: exceptions anywhere in this block go there.
    property handler : BlockId? = nil
    # Code after a jump has no predecessors. To keep editing such code
    # useful it is analysed with the state of the block it followed
    # lexically, without flowing into reachable blocks.
    property fallback : BlockId? = nil
    # For a rescue dispatch block: blocks whose exceptions it catches. Its
    # entry state joins their entry and exit states.
    getter exc_preds = [] of BlockId

    def initialize(@id)
    end
  end

  # Per-body control-flow graph over HIR expressions. Not SSA: operations
  # read and write bindings in an environment.
  class CFG
    ENTRY = BlockId.new(0)
    EXIT  = BlockId.new(1)

    getter blocks : Array(Block)
    # Values flowing into a join expression (`if`, `case`, `&&`, `||`,
    # `begin`, a call's block).
    getter merges : Hash(HIR::ExprId, Array(Source))
    # Block holding each expression's `Eval` (`Enter` for closure bodies is
    # in the closure's head block).
    getter eval_block : Hash(HIR::ExprId, BlockId)
    # Call or proc literal owning a block expression.
    getter closure_owner : Hash(HIR::ExprId, HIR::ExprId)

    def initialize(@blocks, @merges, @eval_block, @closure_owner)
    end

    def [](id : BlockId) : Block
      @blocks[id.value]
    end

    def entry : Block
      self[ENTRY]
    end

    def exit : Block
      self[EXIT]
    end
  
    def dump(body : HIR::Body, text : String, io : IO) : Nil
      snippet = ->(id : HIR::ExprId) do
        r = body.expr(id).range
        t = text.byte_slice(r.start, r.size).gsub(/\s+/, " ")
        t.size > 30 ? t[0, 27] + "..." : t
      end
      @blocks.each do |b|
        io << "bb" << b.id.value
        io << " preds=" << b.preds.map(&.value).join(',') unless b.preds.empty?
        io << " exc_preds=" << b.exc_preds.map(&.value).join(',') unless b.exc_preds.empty?
        io << " handler=bb" << b.handler.not_nil!.value if b.handler
        io << " fallback=bb" << b.fallback.not_nil!.value if b.fallback
        io << '\n'
        b.ops.each do |op|
          e = body.expr(op.expr)
          io << "  " << (op.kind.enter? ? "enter " : "") << e.kind.to_s.downcase
          io << ' ' << e.name if e.name && !op.kind.enter?
          io << " `" << snippet.call(op.expr) << "`\n"
        end
        io << "  " << b.terminator.to_s.downcase
        if t = b.test
          io << ' ' << (t.kind.case_when? ? "when " : "") << '`' << snippet.call(t.cond) << '`'
        end
        io << " -> " << b.succs.map { |s| "bb#{s.value}" }.join(", ") unless b.succs.empty?
        io << '\n'
      end
    end
  end
end
