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
