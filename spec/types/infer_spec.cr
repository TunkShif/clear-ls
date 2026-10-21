require "../spec_helper"

include ClearLS

require "../support/prelude"

def def_node_in(trees : Hash(Int32, Syntax::Tree), site : Semantics::Site) : Syntax::Node?
  t = trees[site.file.value]? || return nil
  n = t.root.descendant(site.item.range.start, site.item.range.end)
  while x = n
    return x if (x.kind.method_def? || x.kind.const_assign?) && x.range == site.item.range
    n = x.parent
  end
  nil
end

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
  inf = Types::Infer.new(body, ctx, table)
  src_tree = tree
  # Def sources for summaries: the prelude (file 0) and this file (1).
  prelude = parser.parse(PRELUDE)
  trees = {0 => prelude, 1 => src_tree}
  inf.source_loader = ->(site : Semantics::Site) { def_node_in(trees, site) }
  inf.summaries = Types::Summaries.new(table)
  {inf.with_source(src).run, body, src, table}
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

describe "Types::Infer modifiers" do
  it "narrows in modifier if/unless bodies" do
    r = infer(<<-CR)
      def m(x : String?)
        a = x if x
        b = x unless x.nil?
        c = x ? x : "d"
      end
      CR
    type_of_local(r, "a").should eq "String"
    type_of_local(r, "b").should eq "String"
    type_of_local(r, "c").should eq "String"
  end
end

# Type of the local *name* where it is read on the line containing *marker*
# (`# here` comments mark the probe).
private def type_at(r, name : String, marker : String) : String
  inf, body, src, table = r
  line_start = src.index!(marker)
  line_start = (src.rindex('\n', line_start) || -1) + 1
  line_end = src.index('\n', line_start) || src.size
  # Last read on the line (`a && a.size` probes the right-hand `a`).
  e = body.exprs.select do |x|
    x.kind.local_ref? && x.name == name && x.range.start >= line_start && x.range.end <= line_end
  end.max_by?(&.range.start) || raise "no read of #{name} on #{marker} line"
  table.to_s(inf.type_of(e.id))
end

describe "Types::Infer control flow" do
  it "is flow-sensitive across reassignments" do
    r = infer(<<-CR)
      def m
        x = 1
        x # a
        x = "s"
        x # b
      end
      CR
    type_at(r, "x", "# a").should eq "Int32"
    type_at(r, "x", "# b").should eq "String"
    type_of_local(r, "x").should eq "Int32 | String"
  end

  it "joins branches, adding Nil for one-sided assignments" do
    r = infer(<<-CR)
      def m(c : Bool)
        if c
          a = 1
          b = 1
        else
          b = "s"
        end
        a # p
        b # p
      end
      CR
    type_at(r, "a", "a # p").should eq "Int32?"
    type_at(r, "b", "b # p").should eq "String | Int32"
  end

  it "drops paths that exit early, also mid-branch" do
    r = infer(<<-CR)
      def m(x : String?, c : Bool)
        if x.nil?
          puts 1
          return
        end
        x # a
        y = nil
        if c
          y = 1
        else
          raise "no"
          y = "dead"
        end
        y # b
      end
      CR
    type_at(r, "x", "x # a").should eq "String"
    type_at(r, "y", "y # b").should eq "Int32"
  end

  it "narrows with &&, ||, !, and falsy edges" do
    r = infer(<<-CR)
      def m(a : String?, b : Int32?)
        if a && b
          a # t1
          b # t1
        end
        if !a || !b
          a # e1
        else
          a # t2
          b # t2
        end
        a && a.size # rhs
        return unless a
        a # t3
      end
      CR
    type_at(r, "a", "a # t1").should eq "String"
    type_at(r, "b", "b # t1").should eq "Int32"
    type_at(r, "a", "a # e1").should eq "String?"
    type_at(r, "a", "a # t2").should eq "String"
    type_at(r, "b", "b # t2").should eq "Int32"
    type_at(r, "a", "a.size # rhs").should eq "String"
    type_at(r, "a", "a # t3").should eq "String"
  end

  it "reaches a fixed point in loops" do
    r = infer(<<-CR)
      def m(c : Bool)
        x = 1
        while c
          x # in
          y = x
          x = "s" if c
          x = nil if c
        end
        x # out
      end
      CR
    type_at(r, "x", "x # in").should eq "Int32 | String | Nil"
    type_at(r, "x", "x # out").should eq "Int32 | String | Nil"
  end

  it "models break and next in loops" do
    r = infer(<<-CR)
      def m(c : Bool)
        x = nil
        while c
          x = 1
          break if c
          x = "s"
          next
          x = :dead
        end
        x # out
      end
      CR
    type_at(r, "x", "x # out").should eq "Int32 | String | Nil"
  end

  it "flows outer reassignments through call blocks" do
    r = infer(<<-CR)
      def m(xs : Array(String))
        acc = nil
        xs.each do |s|
          acc # in
          acc = s
        end
        acc # out
      end
      CR
    type_at(r, "acc", "acc # in").should eq "String?"
    type_at(r, "acc", "acc # out").should eq "String?"
  end

  it "keeps analysing code after an exit" do
    r = infer("def m(s : String)\n  return\n  t = s.size\n  t # dead\nend")
    type_at(r, "t", "t # dead").should eq "Int32"
  end
end

describe "Types::Infer case and rescue" do
  it "narrows the case subject by when/in clauses" do
    r = infer(<<-CR)
      def m(x : Int32 | String | Nil)
        case x
        when String
          x # s
        when nil
          x # n
        else
          x # e
        end
        case x
        when .nil? then x # dn
        when Int32, String then x # many
        end
        case x
        in Int32 then 1
        in String then x # in
        in Nil then 2
        end
        case x
        when 1 then x # lit
        end
      end
      CR
    type_at(r, "x", "x # s").should eq "String"
    type_at(r, "x", "x # n").should eq "Nil"
    type_at(r, "x", "x # e").should eq "Int32"
    type_at(r, "x", "x # dn").should eq "Nil"
    type_at(r, "x", "x # many").should eq "Int32 | String"
    type_at(r, "x", "x # in").should eq "String"
    type_at(r, "x", "x # lit").should eq "Int32"
  end

  it "joins case results and types case without else as nilable" do
    r = infer(<<-CR)
      def m(x : Int32 | String)
        a = case x
            when Int32 then 1
            when String then "s"
            end
        b = case x
            in Int32 then 1
            in String then "s"
            end
      end
      CR
    type_of_local(r, "a").should eq "Int32 | String | Nil"
    type_of_local(r, "b").should eq "Int32 | String"
  end

  it "types rescue variables and rescue/ensure paths" do
    r = infer(<<-CR)
      def m(c : Bool)
        x = 1
        begin
          x = "s"
          raise "no" if c
          y = 1
        rescue e : IO::Error
          e # io
          x # r
        rescue any
          any # any
        ensure
          x # ens
        end
        v = (1 rescue "s")
      end
      CR
    type_at(r, "e", "e # io").should eq "IO::Error"
    type_at(r, "any", "any # any").should eq "Exception"
    type_at(r, "x", "x # r").should eq "Int32 | String"
    type_at(r, "x", "x # ens").should eq "Int32 | String"
    type_of_local(r, "v").should eq "Int32 | String"
  end
end

describe "Types::Infer accessor defaults" do
  it "types getters declared with only a default value" do
    r = infer(<<-CR, 0)
      class Box
        getter items = [] of String
        class_getter count = 0
        getter! cfg : Int32
      end
      def m(b : Box)
        x = b.items
        n = Box.count
        c = b.cfg
        d = b.cfg?
      end
      CR
    type_of_local(r, "x").should eq "Array(String)"
    type_of_local(r, "n").should eq "Int32"
    type_of_local(r, "c").should eq "Int32"
    type_of_local(r, "d").should eq "Int32?"
  end
end

describe "Types::Infer return summaries" do
  it "infers returns of unannotated defs, with argument types" do
    r = infer(<<-CR, 3)
      class Item
        getter name : String
        def initialize(@name)
        end
        def label
          name + "!"
        end
        def twice(x)
          x
        end
      end
      def m(i : Item)
        a = i.label
        b = i.twice(1)
        c = i.twice("s")
        d = helper(i)
      end
      def helper(i)
        return nil if i.name.size > 3
        i.name.size
      end
      CR
    type_of_local(r, "a").should eq "String"
    type_of_local(r, "b").should eq "Int32"
    type_of_local(r, "c").should eq "String"
    type_of_local(r, "d").should eq "Int32?"
  end

  it "terminates on recursion and keeps non-recursive paths" do
    r = infer(<<-CR, 0)
      def m
        f = fact(3)
        g = ping(1)
      end
      def fact(n)
        return 1 if n == 0
        n * fact(n - 1)
      end
      def ping(n)
        n > 0 ? pong(n) : "done"
      end
      def pong(n)
        ping(n - 1)
      end
      CR
    type_of_local(r, "f").should eq "Int32"
    type_of_local(r, "g").should eq "String"
  end
end

describe "Types::Infer typeof and constants" do
  it "types typeof in collection literals and constant expressions" do
    r = infer(<<-CR, 0)
      XS = [1, 2]
      NAMES = %w(a b)
      def m(s : String)
        a = [] of typeof(s.size)
        h = {} of String => typeof(s)
        t = typeof(s)
        x = XS
        n = NAMES
      end
      CR
    type_of_local(r, "a").should eq "Array(Int32)"
    type_of_local(r, "h").should eq "Hash(String, String)"
    type_of_local(r, "t").should eq "String.class"
    type_of_local(r, "x").should eq "Array(Int32)"
    type_of_local(r, "n").should eq "Array(String)"
  end
end
