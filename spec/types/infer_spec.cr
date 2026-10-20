require "../spec_helper"

include ClearLS

require "../support/prelude"

private def infer(src : String, line_of_def = 0) : {Types::Infer, HIR::Body, String, Types::TypeTable}
  parser = Syntax::Parser.new
  map = Semantics::DefMap.new
  map.add_file(FileId.new(0), Items::Lower.lower(parser.parse(PRELUDE)))
  tree = parser.parse(src)
  map.add_file(FileId.new(1), Items::Lower.lower(tree))
  table = Types::TypeTable.new(map)
  defs = [] of Syntax::Node
  tree.root.walk { |n| defs << n if n.kind.method_def?; true }
  node = defs[line_of_def]
  ns = map.namespace_at(FileId.new(1), node.start_byte)
  self_t = ns == Semantics::DefMap::PROGRAM ? table.unknown : table.named(ns, map[ns].type_params.map { |p| table.type_param(p) })
  body = HIR::LowerBody.lower(node)
  ctx = Types::DefContext.new(ns, self_t, map[ns].type_params)
  {Types::Infer.new(body, ctx, table).with_source(src).run, body, src, table}
end

# Type of the binding named *name* at its last reference.
private def type_of_local(r, name : String) : String
  inf, body, _, table = r
  b = body.bindings.select(&.name.== name).last
  table.to_s(inf.binding_type(b.id))
end

# Type of the expression whose source text is *text*.
private def type_of_expr(r, text : String) : String
  inf, body, src, table = r
  e = body.exprs.select { |x| src.byte_slice(x.range.start, x.range.size) == text }.last? || raise "no expr #{text}"
  table.to_s(inf.type_of(e.id))
end

describe Types::TypeExprParser do
  it "parses restrictions" do
    map = Semantics::DefMap.new
    map.add_file(FileId.new(0), Items::Lower.lower(Syntax::Parser.new.parse(PRELUDE)))
    t = Types::TypeTable.new(map)
    p = ->(s : String) { t.to_s(Types::TypeExprParser.parse(s, t, Semantics::DefMap::PROGRAM, ["T"])) }
    p.call("Int32").should eq "Int32"
    p.call("Array(String)?").should eq "Array(String)?"
    p.call("Int32 | String | Nil").should eq "Int32 | String | Nil"
    p.call("{Int32, String}").should eq "{Int32, String}"
    p.call("{a: Int32, b: String}").should eq "{a: Int32, b: String}"
    p.call("Int32, String -> Bool").should eq "Int32, String -> Bool"
    p.call("-> Nil").should eq "-> Nil"
    p.call("Hash(String, Array(T))").should eq "Hash(String, Array(T))"
    p.call("Int32.class").should eq "Int32.class"
    p.call("UInt8*").should eq "Pointer(UInt8)"
    p.call("Missing::Type").should eq "?"
    p.call("(Int32 -> Nil)?").should eq "(Int32 -> Nil)?"
  end
end

describe Types::Infer do
  it "types literals and collections" do
    r = infer(<<-CR)
      def m
        a = 1
        b = 1_i64
        c = 2.5
        d = "s"
        e = :sym
        f = [1, 2]
        g = [] of String
        h = {"a" => 1}
        i = {} of String => Array(Int32)
        j = {1, "x"}
        k = {name: "n", age: 1}
        l = 1..2
        n = nil
        o = 'c'
        q = [1, "s"]
        s = Set{1}
      end
      CR
    {"a" => "Int32", "b" => "Int64", "c" => "Float64", "d" => "String", "e" => "Symbol",
     "f" => "Array(Int32)", "g" => "Array(String)", "h" => "Hash(String, Int32)",
     "i" => "Hash(String, Array(Int32))", "j" => "{Int32, String}", "k" => "{name: String, age: Int32}",
     "l" => "Range(Int32, Int32)", "n" => "Nil", "o" => "Char", "q" => "Array(Int32 | String)",
     "s" => "Set(Int32)"}.each do |name, ty|
      type_of_local(r, name).should eq ty
    end
  end

  it "uses parameter restrictions and declared returns" do
    r = infer(<<-CR)
      def m(s : String, io : IO, n = 1)
        len = s.size
        up = s.upcase.size
        line = io.gets
        sum = n + 1
      end
      CR
    type_of_local(r, "len").should eq "Int32"
    type_of_local(r, "up").should eq "Int32"
    type_of_local(r, "line").should eq "String?"
    type_of_local(r, "n").should eq "?"
    type_of_local(r, "sum").should eq "?"
  end

  it "substitutes generics from the receiver, includes, and forall" do
    r = infer(<<-CR)
      def m(xs : Array(String), h : Hash(String, Int32))
        first = xs.first
        maybe = xs.first?
        lens = xs.map { |x| x.size }
        idx = xs[0]
        keys = h.keys
        v = h["a"]
      end
      CR
    type_of_local(r, "first").should eq "String"
    type_of_local(r, "maybe").should eq "String?"
    type_of_local(r, "x").should eq "String"
    type_of_local(r, "lens").should eq "Array(Int32)"
    type_of_local(r, "idx").should eq "String"
    type_of_local(r, "keys").should eq "Array(String)"
    type_of_local(r, "v").should eq "Int32"
  end

  it "types block args, including tuple splatting" do
    r = infer(<<-CR)
      def m(h : Hash(String, Int32), xs : Array(String))
        h.each { |k, v| k }
        xs.each_with_index { |s, i| s }
        3.times { |t| t }
      end
      CR
    type_of_local(r, "k").should eq "String"
    type_of_local(r, "v").should eq "Int32"
    type_of_local(r, "s").should eq "String"
    type_of_local(r, "i").should eq "Int32"
    type_of_local(r, "t").should eq "Int32"
  end

  it "constructs instances with .new and generic args" do
    r = infer(<<-CR, 1)
      class Point
        def initialize(@x : Int32)
        end
      end
      def m
        p = Point.new(1)
        a = Array(String).new
        s = String.new
      end
      CR
    type_of_local(r, "p").should eq "Point"
    type_of_local(r, "a").should eq "Array(String)"
    type_of_local(r, "s").should eq "String"
  end

  it "joins branches and narrows nil and is_a?" do
    r = infer(<<-CR)
      def m(io : IO, x : Int32 | String)
        v = if io
              1
            else
              "s"
            end
        line = io.gets
        if line
          inside = line
        end
        if x.is_a?(Int32)
          num = x
        else
          str = x
        end
        only_then = 1 if io
        c = line.not_nil!
      end
      CR
    type_of_local(r, "v").should eq "Int32 | String"
    type_of_local(r, "inside").should eq "String"
    type_of_local(r, "num").should eq "Int32"
    type_of_local(r, "str").should eq "String"
    type_of_local(r, "c").should eq "String"
  end

  it "types ivars from declarations, accessors, and initialize params" do
    r = infer(<<-CR, 1)
      class User
        @age : Int32
        getter name : String
        def initialize(@email : String, @name)
          @age = 0
        end
        def show
          a = @age
          n = @name
          e = @email
          u = self
        end
      end
      CR
    type_of_local(r, "a").should eq "Int32"
    type_of_local(r, "n").should eq "String"
    type_of_local(r, "e").should eq "String"
    type_of_local(r, "u").should eq "User"
  end

  it "types constants, casts, op-assign, and procs" do
    r = infer(<<-CR)
      LIMIT = 10
      NAME = "x"
      def m(x)
        l = LIMIT
        n = NAME
        c = x.as(String)
        d = x.as?(Int32)
        total = 0
        total += 1
        f = ->(a : Int32) { a + 1 }
        cls = String
      end
      CR
    type_of_local(r, "l").should eq "Int32"
    type_of_local(r, "n").should eq "String"
    type_of_local(r, "c").should eq "String"
    type_of_local(r, "d").should eq "Int32?"
    type_of_local(r, "total").should eq "Int32"
    type_of_local(r, "f").should eq "Int32 -> Int32"
    type_of_local(r, "cls").should eq "String.class"
  end

  it "leaves unknowns unknown instead of guessing" do
    r = infer("def m(x)\n  y = x.whatever\n  z = undefined_call\nend")
    type_of_local(r, "y").should eq "?"
    type_of_local(r, "z").should eq "?"
  end

  it "types expressions in a call chain" do
    r = infer("def m(s : String)\n  s.split(\",\").map { |p| p.upcase }.first\nend")
    type_of_expr(r, %(s.split(","))).should eq "Array(String)"
    type_of_local(r, "p").should eq "String"
  end
end

describe "Types::Infer nil handling" do
  it "handles `|| return`, `|| default`, `try`, `not_nil!`" do
    r = infer(<<-CR)
      def m(x : String?, y : Int32?)
        a = x || return
        b = y || 0
        t = x.try { |s| s.size }
        d = x.not_nil!.size
      end
      CR
    type_of_local(r, "a").should eq "String"
    type_of_local(r, "b").should eq "Int32"
    type_of_local(r, "s").should eq "String"
    type_of_local(r, "t").should eq "Int32?"
    type_of_local(r, "d").should eq "Int32"
  end
end

describe "Types::Infer overload selection" do
  it "prefers the blockless overload when no block is given" do
    r = infer(<<-CR, 2)
      module Picky(T)
        def pick(&)
          yield
        end
        def pick : T
        end
      end
      class Box(T)
        include Picky(T)
      end
      def m(b : Box(String))
        v = b.pick
      end
      CR
    type_of_local(r, "v").should eq "String"
  end
end
