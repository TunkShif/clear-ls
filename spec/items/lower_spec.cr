require "../spec_helper"

include ClearLS
include ClearLS::Items

private def items_of(src : String) : ItemTree
  Lower.lower(Syntax::Parser.new.parse(src))
end

private def dump(src : String) : String
  tree = Syntax::Parser.new.parse(src)
  String.build { |io| Dump.dump(Lower.lower(tree), tree.line_index, io) }
end

private def find(tree : ItemTree, name : String) : Item
  found = nil
  tree.each_item { |i| found ||= i if i.name == name }
  found || raise "no item #{name}"
end

describe Lower do
  it "lowers nested namespaces with paths, generics, and superclasses" do
    t = items_of(<<-CR)
      module Outer::Inner
        abstract class Base(K, *V) < ::Parent(K)
        end
        struct Point; end
      end
      CR
    mod = t.items[0]
    mod.kind.should eq ItemKind::Module
    mod.name.should eq "Inner"
    mod.header.not_nil!.path.should eq ["Outer", "Inner"]
    base = mod.children[0]
    h = base.header.not_nil!
    {h.type_params, h.splat_index, h.superclass, h.is_abstract}.should eq({["K", "V"], 1, "::Parent(K)", true})
    mod.children[1].kind.should eq ItemKind::Struct
  end

  it "keeps full signatures" do
    t = items_of(<<-CR)
      class A
        def self.make(ext int : Int32, *rest, named : String = "x", **opts, &block : -> Nil) : A forall T
        end
      end
      CR
    d = find(t, "make")
    s = d.signature.not_nil!
    s.receiver.should eq "self"
    s.return_type.should eq "A"
    s.free_vars.should eq ["T"]
    s.params.map(&.kind).should eq [ParamKind::Positional, ParamKind::Splat, ParamKind::Positional, ParamKind::DoubleSplat, ParamKind::Block]
    s.params[0].call_name.should eq "ext"
    s.params[0].name.should eq "int"
    s.params[2].default.should eq %("x")
    s.to_s.should eq %((ext int : Int32, *rest, named : String = "x", **opts, &block : -> Nil) : A forall T)
  end

  it "tracks visibility, annotations, and doc comments" do
    t = items_of(<<-CR)
      class A
        # Doc line one
        # line two
        @[Deprecated]
        private def a; end

        # detached

        protected def b; end
      end
      CR
    a = find(t, "a")
    a.visibility.should eq Visibility::Private
    a.annotations.should eq ["Deprecated"]
    a.doc.should eq "Doc line one\nline two"
    b = find(t, "b")
    b.visibility.should eq Visibility::Protected
    b.doc.should be_nil
  end

  it "lowers enums, constants, aliases, includes, and ivars" do
    t = items_of(<<-CR)
      module M
        include Comparable(M)
        extend self
        X = 1
        alias Cb = Int32 -> Nil
        enum Color : UInt8
          Red = 1
          Green
        end
        class C
          @x : Int32
          @@count = 0
        end
      end
      CR
    m = t.items[0]
    m.includes.should eq ["Comparable(M)"]
    m.extends.should eq ["self"]
    find(t, "X").detail.should eq "1"
    find(t, "Cb").kind.should eq ItemKind::Alias
    color = find(t, "Color")
    color.header.not_nil!.base_type.should eq "UInt8"
    color.children.map(&.name).should eq ["Red", "Green"]
    find(t, "@x").kind.should eq ItemKind::InstanceVar
  end

  it "lowers lib declarations" do
    dump(<<-CR).should eq <<-OUT
      lib LibC
        alias Char = UInt8
        type Handle = Void*
        struct S
          a, b : Int32
        end
        union U
          f : Float64
        end
        fun printf(fmt : Char*, ...) : Int32
        fun my_puts = puts(Char*) : Int32
        $errno : Int32
      end
      CR
      lib LibC @0:4
        alias Char : UInt8 @1:8
        typedef Handle : Void* @2:7
        cstruct S @3:9
          cfield a : Int32 @4:4
          cfield b : Int32 @4:7
        cunion U @6:8
          cfield f : Float64 @7:4
        fun printf(fmt : Char*, ...) : Int32 @9:6
        fun my_puts = puts(Char*) : Int32 @10:6
        cvar errno : Int32 @11:3

      OUT
  end

  it "synthesises accessors from getter/property macros" do
    dump(<<-CR).should eq <<-OUT
      class A
        getter x : Int32, y = 0
        property? ok : Bool
        class_getter count = 0
        getter! z : String
      end
      CR
      class A @0:6
        def x() : Int32 @1:9 [macro]
        instancevar @x : Int32 @1:9 [macro]
        def y() @1:20 [macro]
        instancevar @y : 0 @1:20 [macro]
        def ok?() : Bool @2:12 [macro]
        def ok=(ok : Bool) @2:12 [macro]
        instancevar @ok : Bool @2:12 [macro]
        def self.count() @3:15 [macro]
        classvar @@count : 0 @3:15 [macro]
        def z() : String @4:10 [macro]
        def z?() : String? @4:10 [macro]
        instancevar @z : String @4:10 [macro]

      OUT
  end

  it "synthesises record structs" do
    t = items_of("record Point, x : Int32, y = 0")
    rec = t.items[0]
    rec.kind.should eq ItemKind::Struct
    rec.origin.should eq Origin::Macro
    rec.children.select(&.kind.def?).map(&.name).should eq ["initialize", "x", "y"]
    rec.children[0].signature.not_nil!.to_s.should eq "(x : Int32, y = 0)"
  end

  it "lowers declarations inside macro conditionals with conditions" do
    t = items_of(<<-CR)
      {% if flag?(:win32) %}
        require "./win"
        class W; end
      {% elsif flag?(:linux) && !flag?(:musl) %}
        class L; end
      {% else %}
        class O; end
      {% end %}
      class C
        {% unless flag?(:x) %}
          def m; end
        {% end %}
      end
      CR
    linux = Items.flags_for_triple("x86_64-unknown-linux-gnu")
    win = Items.flags_for_triple("x86_64-pc-windows-msvc")
    visible = ->(name : String, flags : Set(String)) { Cond.all(find(t, name).conditions, flags) }
    visible.call("W", linux).should be_false
    visible.call("W", win).should be_true
    visible.call("L", linux).should be_true
    visible.call("O", linux).should be_false
    visible.call("m", linux).should be_true
    t.requires[0].path.should eq "./win"
    Cond.all(t.requires[0].conditions, win).should be_true
  end

  it "treats non-flag conditions as unknown" do
    t = items_of(%({% if compare_versions(Crystal::VERSION, "1.0.0") > 0 %}\nclass V; end\n{% end %}))
    Cond.all(find(t, "V").conditions, Set{"linux"}).should be_nil
  end

  it "recovers declarations from half-typed code" do
    ["x.", "if x", "y = "].each do |broken|
      t = items_of("module M\n  class A < B\n    def foo\n      #{broken}\n    end\n    def bar; end\n  end\n  def baz; end\nend\n")
      t.recovered.should be_true
      m = t.items[0]
      {m.kind, m.name}.should eq({ItemKind::Module, "M"})
      names = [] of String
      t.each_item { |i| names << i.name }
      names.should contain("A")
      names.should contain("foo")
      names.should contain("bar")
    end
  end
end

describe "ItemTree#fingerprint" do
  base = "class A\n  # doc\n  def foo(x)\n    x + 1\n  end\nend\n"

  it "ignores def bodies and whitespace" do
    a = items_of(base).fingerprint
    items_of(base.sub("x + 1", "x * 2 + call(3)")).fingerprint.should eq a
    items_of("\n\n" + base).fingerprint.should eq a
  end

  it "changes when declarations change" do
    a = items_of(base).fingerprint
    items_of(base.sub("foo(x)", "foo(x, y)")).fingerprint.should_not eq a
    items_of(base.sub("# doc", "# other")).fingerprint.should_not eq a
    items_of(base.sub("class A", "class B")).fingerprint.should_not eq a
    items_of(base + "require \"x\"\n").fingerprint.should_not eq a
  end
end

describe Items do
  it "computes compiler-style target flags" do
    Items.flags_for_triple("x86_64-unknown-linux-gnu").should eq Set{"x86_64", "unknown", "linux", "gnu", "bits64", "unix"}
    Items.flags_for_triple("aarch64-apple-darwin").should contain("darwin")
    win = Items.flags_for_triple("x86_64-pc-windows-msvc")
    win.should contain("win32")
    win.should_not contain("unix")
  end
end
