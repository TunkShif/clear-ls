require "../spec_helper"

include ClearLS

private def body_of(src : String) : {HIR::Body, String}
  tree = Syntax::Parser.new.parse(src)
  node = nil
  tree.root.walk { |n| node ||= n if n.kind.method_def?; true }
  {HIR::LowerBody.lower(node.not_nil!), src}
end

# HIR::Binding referenced at the *nth* occurrence of *needle* (cursor at its start).
private def binding_at(body : HIR::Body, src : String, needle : String, nth = 0) : HIR::Binding?
  off = 0
  (nth + 1).times { |i| off = src.index!(needle, i == 0 ? 0 : off + 1) }
  body.binding_at(src.byte_index(needle, src.char_index_to_byte_index(off).not_nil!).not_nil!.to_u32).try(&.[0])
end

private def refs(b : HIR::Binding, src : String) : Array(String)
  b.references.map { |r| "#{r.kind.to_s.downcase[0]}#{src.byte_slice(0, r.range.start).count('\n') + 1}" }
end

describe HIR::LowerBody do
  it "binds params, including defaults that see earlier params" do
    body, src = body_of("def m(a, b = a, *rest, ext int = 1, **opts, &blk)\n  a + int + rest.size\nend")
    body.bindings.map(&.name).should eq ["a", "b", "rest", "int", "opts", "blk"]
    a = binding_at(body, src, "a", 1).not_nil!
    a.name.should eq "a"
    refs(a, src).should eq ["d1", "r1", "r2"]
    body.bindings.find!(&.name.== "blk").kind.should eq HIR::BindingKind::BlockParam
  end

  it "lowers splats in collection literals and marks splat targets" do
    body, src = body_of("def m(xs, t, mix)\n  a = [1, *xs]\n  b = {*t, 2}\n  q, *r = 1, 2, 3\n  c = {1, *{\"a\", 2}}\n  d = Set{*mix}\nend")
    splats = body.exprs.select(&.kind.splat?).map { |e| src.byte_slice(e.range.start, e.range.size) }
    splats.should eq ["*xs", "*t", "*r", "*{\"a\", 2}", "*mix"]
    body.exprs.any?(&.kind.missing?).should be_false
    body.bindings.find!(&.name.== "mix").references.map(&.kind).should eq [HIR::RefKind::Decl, HIR::RefKind::Read]
    xs = body.bindings.find!(&.name.== "xs")
    xs.references.map(&.kind).should eq [HIR::RefKind::Decl, HIR::RefKind::Read]
    body.bindings.map(&.name).should contain "r"
  end

  it "binds ivar params as locals too" do
    body, src = body_of("def initialize(@name : String, @@count = 0)\n  name.size + count\nend")
    name = body.bindings.find!(&.name.== "name")
    name.restriction.should eq "String"
    src.byte_slice(name.name_range.start, name.name_range.size).should eq "name"
    refs(name, src).should eq ["d1", "r2"]
    body.bindings.map(&.name).should eq ["name", "count"]
  end

  it "declares locals at first assignment; value is lowered first" do
    body, src = body_of("def m\n  foo\n  foo = foo\n  foo\nend")
    foo = body.bindings.find!(&.name.== "foo")
    refs(foo, src).should eq ["d3", "r4"]
    # Line 2 and the rhs on line 3 are method calls.
    calls = body.exprs.select { |e| e.kind.call? && e.name == "foo" }
    calls.size.should eq 2
  end

  it "keeps block-assigned locals inside the block, but reassigns outer ones" do
    body, src = body_of(<<-CR)
      def m
        outer = 1
        [1].each do |x|
          outer = x
          inner = x
        end
        inner
        outer
      end
      CR
    outer = body.bindings.find!(&.name.== "outer")
    refs(outer, src).should eq ["d2", "w4", "r8"]
    inner = body.bindings.find!(&.name.== "inner")
    inner.scope.value.should eq 1
    refs(inner, src).should eq ["d5"]
    # The `inner` after the block is a call, not the block local.
    body.exprs.count { |e| e.kind.call? && e.name == "inner" }.should eq 1
  end

  it "lets block params shadow outer locals" do
    body, src = body_of(<<-CR)
      def m
        value = 1
        items.each do |value|
          value.to_s
        end
        value.abs
      end
      CR
    vals = body.bindings.select(&.name.== "value")
    vals.size.should eq 2
    refs(vals[0], src).should eq ["d2", "r6"]
    refs(vals[1], src).should eq ["d3", "r4"]
  end

  it "shares scope across if/while/begin and handles conditions" do
    body, src = body_of(<<-CR)
      def m
        if (w = compute) && w > 1
          v = w
        end
        while x = next_one
          y = x
        end
        v; y
      end
      CR
    refs(body.bindings.find!(&.name.== "w"), src).should eq ["d2", "r2", "r3"]
    refs(body.bindings.find!(&.name.== "v"), src).should eq ["d3", "r8"]
    refs(body.bindings.find!(&.name.== "y"), src).should eq ["d6", "r8"]
  end

  it "binds rescue variables, multi-assign, op-assign, and type declarations" do
    body, src = body_of(<<-CR)
      def m
        a, b = 1, 2
        a += b
        c ||= a
        d : Int32 = c
        begin
          d
        rescue ex : IO::Error
          ex.message
        end
      end
      CR
    refs(body.bindings.find!(&.name.== "a"), src).should eq ["d2", "r3", "w3", "r4"]
    refs(body.bindings.find!(&.name.== "c"), src).should eq ["d4", "r5"]
    d = body.bindings.find!(&.name.== "d")
    {d.kind, d.restriction}.should eq({HIR::BindingKind::TypeDecl, "Int32"})
    ex = body.bindings.find!(&.name.== "ex")
    {ex.kind, ex.restriction}.should eq({HIR::BindingKind::RescueVar, "IO::Error"})
    refs(ex, src).should eq ["d8", "r9"]
  end

  it "scopes proc literal params" do
    body, src = body_of("def m\n  x = 1\n  f = ->(p : Int32) { p + x }\n  p\nend")
    p_ = body.bindings.find!(&.name.== "p")
    p_.kind.should eq HIR::BindingKind::BlockArg
    refs(p_, src).should eq ["d3", "r3"]
    refs(body.bindings.find!(&.name.== "x"), src).should eq ["d2", "r3"]
  end

  it "lowers calls with receivers, named args, and blocks" do
    body, _ = body_of("def m(x)\n  a.b(x, key: 1) { |i| i }\nend")
    call = body.exprs.find! { |e| e.kind.call? && e.name == "b" }
    body.expr(call.receiver.not_nil!).name.should eq "a"
    call.children.size.should eq 1
    call.named_args.map(&.[0]).should eq ["key"]
    body.expr(call.block.not_nil!).kind.should eq HIR::ExprKind::Block
  end

  it "keeps resolving locals in broken code" do
    body, src = body_of("def m\n  value = 1\n  value.\n  other = value\nend")
    refs(body.bindings.find!(&.name.== "value"), src).should contain("r3")
  end

  it "finds visible bindings and innermost expression at an offset" do
    body, src = body_of("def m(a)\n  b = 1\n  [1].each do |c|\n    d = c\n    \n  end\nend")
    at = src.index!("    \n").to_u32 + 4
    body.visible_bindings(at).map(&.name).sort.should eq ["a", "b", "c", "d"]
    body.visible_bindings(src.index!("b = 1").to_u32).map(&.name).should eq ["a"]
    e = body.expr_at(src.index!("c\n").to_u32).not_nil!
    {e.kind, e.name}.should eq({HIR::ExprKind::LocalRef, "c"})
  end
end

describe "LowerBody file bodies" do
  it "lowers top-level code, skipping defs and isolating type bodies" do
    src = "x = 1\nputs x\ndef m\n  x\nend\nclass C\n  y = x\nend\n"
    tree = Syntax::Parser.new.parse(src)
    body = HIR::LowerBody.lower(tree.root)
    x = body.bindings.find!(&.name.== "x")
    x.references.size.should eq 2 # decl + `puts x`; not the def, not the class body
    y = body.bindings.find!(&.name.== "y")
    body.scope(y.scope).parent.should be_nil
  end
end

# Kind tree of an expression: `if(localref,seq,nop)`.
private def shape(body : HIR::Body, id : HIR::ExprId) : String
  e = body.expr(id)
  kids = e.children.map { |c| shape(body, c) }
  kids.empty? ? e.kind.to_s.downcase : "#{e.kind.to_s.downcase}(#{kids.join(',')})"
end

describe "HIR::LowerBody control-flow shapes" do
  it "lowers if/unless/modifiers/elsif/ternary as [cond, then, else]" do
    body, _ = body_of(<<-CR)
      def m(x)
        1 if x
        2 unless x
        x ? 1 : 2
        if x
        elsif x
          3
        end
      end
      CR
    stmts = body.expr(body.root).children.map { |c| shape(body, c) }
    stmts.should eq [
      "if(localref,literal,nop)",
      "unless(localref,literal,nop)",
      "if(localref,literal,literal)",
      "if(localref,nop,if(localref,seq(literal),nop))",
    ]
  end

  it "lowers case clauses and rescue/ensure" do
    body, _ = body_of(<<-CR)
      def m(x)
        case x
        when Int32, Nil then 1
        else 2
        end
        case
        when x then 1
        end
        begin
          1
        rescue e : IO::Error
          e
        else
          2
        ensure
          3
        end
        1 rescue 2
      end
      CR
    stmts = body.expr(body.root).children.map { |c| shape(body, c) }
    stmts.should eq [
      "case(localref,when(const,const,seq(literal)),seq(seq(literal)))",
      "case(nop,when(localref,seq(literal)))",
      "begin(seq(literal),rescue(seq(localref)),seq(seq(literal)),seq(seq(literal)))",
      "begin(literal,rescue(literal))",
    ]
    resc = body.exprs.find!(&.kind.rescue?)
    resc.type_text.should eq "IO::Error"
    body.binding(resc.binding.not_nil!).name.should eq "e"
  end
end

describe "HIR::LowerBody call arguments" do
  it "distinguishes splats, block passes, and implicit-object blocks" do
    body, _ = body_of("def m(xs, f)\n  foo(1, *xs, **xs, k: 2, \"s\": 3, &f)\n  xs.each(&.size)\nend")
    call = body.exprs.find! { |e| e.kind.call? && e.name == "foo" }
    call.children.map { |c| body.expr(c).kind.to_s.downcase }.should eq ["literal", "splat", "doublesplat"]
    call.named_args.map(&.[0]).should eq ["k", "s"]
    body.expr(call.block.not_nil!).syntax.should eq Syntax::Kind::BlockArgument
    each = body.exprs.find! { |e| e.kind.call? && e.name == "each" }
    body.expr(each.block.not_nil!).syntax.should eq Syntax::Kind::ImplicitObjectCall
  end
end
