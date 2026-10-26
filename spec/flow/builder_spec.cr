require "../spec_helper"

include ClearLS

private def cfg_of(src : String) : {Flow::CFG, HIR::Body, String}
  tree = Syntax::Parser.new.parse(src)
  node = nil
  tree.root.walk { |n| node ||= n if n.kind.method_def?; true }
  body = HIR::LowerBody.lower(node.not_nil!)
  {Flow::Builder.build(body), body, src}
end

private def text(body : HIR::Body, src : String, id : HIR::ExprId) : String
  r = body.expr(id).range
  src.byte_slice(r.start, r.size)
end

# Blocks reachable from entry, following normal and exception edges.
private def reachable(cfg : Flow::CFG) : Set(Int32)
  seen = Set(Int32).new
  work = [Flow::CFG::ENTRY]
  while id = work.pop?
    next unless seen.add?(id.value)
    b = cfg[id]
    work.concat(b.succs)
    b.handler.try { |h| work << h }
  end
  seen
end

# Source texts of the expressions evaluated in reachable blocks.
private def reachable_evals(cfg, body, src) : Array(String)
  r = reachable(cfg)
  cfg.blocks.select { |b| r.includes?(b.id.value) }.flat_map(&.ops).select(&.kind.eval?).map { |o| text(body, src, o.expr) }
end

describe Flow::Builder do
  it "evaluates operands before their expression" do
    cfg, body, src = cfg_of("def m\n  a = 1 + 2\n  a\nend")
    cfg.entry.ops.map { |o| text(body, src, o.expr) }.should eq ["1", "2", "1 + 2", "a = 1 + 2", "a", "a = 1 + 2\n  a\n"]
    cfg.entry.terminator.should eq Flow::Terminator::Return
  end

  it "splits && / || / ! conditions into branch chains" do
    cfg, body, src = cfg_of("def m(a, b)\n  if a && !b\n    1\n  end\nend")
    tests = cfg.blocks.compact_map(&.test).map { |t| text(body, src, t.cond) }
    tests.should eq ["a", "b"]
    # `!b` swaps the edges: its true edge goes to the else side.
    b_test = cfg.blocks.find! { |bl| bl.test.try { |t| text(body, src, t.cond) == "b" } }
    then_b = cfg.blocks.find! { |bl| bl.ops.any? { |o| text(body, src, o.expr) == "1" } }
    b_test.succs[1].should eq then_b.id
  end

  it "makes code after jumps unreachable, with a lexical fallback" do
    cfg, body, src = cfg_of(<<-CR)
      def m(x)
        if x
          return 1
          dead1
        end
        while x
          break
          dead2
        end
        live
      end
      CR
    evals = reachable_evals(cfg, body, src)
    evals.should contain "live"
    evals.should_not contain "dead1"
    evals.should_not contain "dead2"
    dead = cfg.blocks.find! { |b| b.ops.any? { |o| text(body, src, o.expr) == "dead1" } }
    dead.fallback.should_not be_nil
  end

  it "loops back from while bodies and call blocks" do
    cfg, body, src = cfg_of("def m(xs, c)\n  while c\n    x = 1\n  end\n  xs.each { |y| y }\nend")
    back = ->(b : Flow::Block) { b.preds.any? { |p| p.value > b.id.value } }
    while_head = cfg.blocks.find! { |b| b.test.try { |t| text(body, src, t.cond) == "c" } }
    back.call(while_head).should be_true
    enter = cfg.blocks.find! { |b| b.ops.any?(&.kind.enter?) }
    back.call(enter).should be_true
  end

  it "exits `while true` only through break" do
    cfg, body, src = cfg_of("def m\n  while true\n    break\n  end\n  live\nend")
    reachable_evals(cfg, body, src).should contain "live"
    cfg.blocks.compact_map(&.test).should be_empty
    cfg, body, src = cfg_of("def m\n  while true\n    x = 1\n  end\n  dead\nend")
    reachable_evals(cfg, body, src).should_not contain "dead"
  end

  it "routes exceptions to rescue clauses and runs ensure after the join" do
    cfg, body, src = cfg_of(<<-CR)
      def m
        begin
          a = 1
        rescue e
          b = 2
        ensure
          c = 3
        end
      end
      CR
    guarded = cfg.blocks.find! { |b| b.ops.any? { |o| text(body, src, o.expr) == "a = 1" } }
    dispatch = cfg[guarded.handler.not_nil!]
    dispatch.exc_preds.should eq [guarded.id]
    clause = cfg[dispatch.succs[0]]
    clause.ops.first.kind.should eq Flow::OpKind::Enter
    ens = cfg.blocks.find! { |b| b.ops.any? { |o| text(body, src, o.expr) == "c = 3" } }
    ens.preds.size.should eq 2
  end

  it "ends case/in without a match in an unreachable terminator" do
    cfg, body, src = cfg_of("def m(x)\n  case x\n  in Int32 then 1\n  end\n  case x\n  when 1 then 2\n  end\nend")
    cfg.blocks.count(&.terminator.==(Flow::Terminator::Unreachable)).should eq 1
    tests = cfg.blocks.compact_map(&.test)
    tests.map(&.kind).uniq.should eq [Flow::TestKind::CaseWhen]
    tests.map { |t| text(body, src, t.subject.not_nil!) }.should eq ["x", "x"]
    case_whens = cfg.merges.select { |id, _| body.expr(id).kind.case? }.values
    case_whens.map(&.size).should eq [1, 2] # `in` has no else source; `when` adds Nil
  end
end
