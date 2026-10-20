require "../spec_helper"
require "../support/prelude"

include ClearLS

# Resolves every call `io.gets(...)` / `o.m(...)` in def `m` and reports
# the viable overloads as signatures.
private def resolutions(src : String, method = "gets") : Array({String, Types::ResolutionKind, Array(String)})
  parser = Syntax::Parser.new
  map = Semantics::DefMap.new
  map.add_file(FileId.new(0), Items::Lower.lower(parser.parse(PRELUDE)))
  tree = parser.parse(src)
  map.add_file(FileId.new(1), Items::Lower.lower(tree))
  table = Types::TypeTable.new(map)
  node = nil
  tree.root.walk { |n| node = n if n.kind.method_def? && n.field_text(Syntax::Field::Name) == "m"; true }
  body = HIR::LowerBody.lower(node.not_nil!)
  ctx = Types::DefContext.new(Semantics::DefMap::PROGRAM, table.unknown, [] of String)
  inf = Types::Infer.new(body, ctx, table).with_source(src).run
  body.exprs.select { |e| e.kind.call? && e.name == method }.map do |call|
    res = inf.resolve_call(call)
    text = src.byte_slice(call.range.start, call.range.size)
    {text, res.kind, res.candidates.map { |c| c.signature.to_s }}
  end
end

GETS_CHOMP     = "(chomp : Bool = true) : String?"
GETS_LIMIT     = "(limit : Int, chomp : Bool = false) : String?"
GETS_CHAR      = "(delimiter : Char, chomp : Bool = false) : String?"
GETS_CHAR_LIM  = "(delimiter : Char, limit : Int, chomp = false) : String?"
GETS_STR       = "(delimiter : String, chomp = false) : String?"
GETS_ONE_ARG   = [GETS_CHOMP, GETS_LIMIT, GETS_CHAR, GETS_STR]

describe Types::CallResolver do
  it "narrows the IO#gets family by literal argument types" do
    r = resolutions(<<-CR)
      def m(io : IO, value, n : Int32, s : String | Char)
        io.gets
        io.gets(false)
        io.gets(10)
        io.gets('x')
        io.gets("END")
        io.gets('x', 100)
        io.gets(100, true)
        io.gets('x', true)
        io.gets("END", true)
        io.gets('x', 100, true)
        io.gets(value)
        io.gets(n)
        io.gets(s)
        io.gets(chomp: false)
        io.gets(limit: 3)
        io.gets(value, value)
      end
      CR
    got = r.to_h { |(t, _, c)| {t, c} }
    got["io.gets"].should eq [GETS_CHOMP]
    got["io.gets(false)"].should eq [GETS_CHOMP]
    got["io.gets(10)"].should eq [GETS_LIMIT]
    got["io.gets('x')"].should eq [GETS_CHAR]
    got[%(io.gets("END"))].should eq [GETS_STR]
    got["io.gets('x', 100)"].should eq [GETS_CHAR_LIM]
    got["io.gets(100, true)"].should eq [GETS_LIMIT]
    got["io.gets('x', true)"].should eq [GETS_CHAR] # `true` cannot be a limit
    got[%(io.gets("END", true))].should eq [GETS_STR]
    got["io.gets('x', 100, true)"].should eq [GETS_CHAR_LIM]
    got["io.gets(value)"].should eq GETS_ONE_ARG
    got["io.gets(n)"].should eq [GETS_LIMIT]
    got["io.gets(s)"].should eq [GETS_CHAR, GETS_STR]
    got["io.gets(chomp: false)"].should eq [GETS_CHOMP]
    got["io.gets(limit: 3)"].should eq [GETS_LIMIT]
    got["io.gets(value, value)"].should eq [GETS_LIMIT, GETS_CHAR, GETS_CHAR_LIM, GETS_STR]
    kinds = r.to_h { |(t, k, _)| {t, k} }
    kinds["io.gets(10)"].should eq Types::ResolutionKind::Unique
    kinds["io.gets(value)"].should eq Types::ResolutionKind::Ambiguous
    kinds["io.gets(s)"].should eq Types::ResolutionKind::MultipleRuntimeTargets
  end

  it "binds defaults, named, external names, splats, double splats, and blocks" do
    r = resolutions(<<-CR, "f")
      class O
        def f(a : Int32, b = 1, *rest, key k : String = "", **opts)
        end
        def f(&)
        end
      end
      def m(o : O, xs : Array(Int32), h)
        o.f(1)
        o.f(1, 2, 3, 4)
        o.f(1, key: "x", other: 1)
        o.f(*xs)
        o.f(**h)
        o.f { }
        o.f
        o.f("s")
      end
      CR
    got = r.to_h { |(t, k, c)| {t, {k, c.size}} }
    got["o.f(1)"].should eq({Types::ResolutionKind::Unique, 1})
    got["o.f(1, 2, 3, 4)"].should eq({Types::ResolutionKind::Unique, 1})
    got[%(o.f(1, key: "x", other: 1))].should eq({Types::ResolutionKind::Unique, 1})
    got["o.f(*xs)"][1].should eq 1
    got["o.f(**h)"][1].should eq 1
    got["o.f { }"].should eq({Types::ResolutionKind::Unique, 1})
    got["o.f"].should eq({Types::ResolutionKind::NameOnly, 0})
    got[%(o.f("s"))].should eq({Types::ResolutionKind::NameOnly, 0})
  end

  it "prefers overrides and more specific restrictions" do
    r = resolutions(<<-CR, "g")
      class Base
        def g(x) : Int32
        end
      end
      class Sub < Base
        def g(x) : String
        end
        def g(x : Int32) : Char
        end
      end
      def m(s : Sub, v)
        s.g(1)
        s.g("a")
        s.g(v)
      end
      CR
    got = r.to_h { |(t, _, c)| {t, c} }
    got["s.g(1)"].should eq ["(x : Int32) : Char"]
    got[%(s.g("a"))].should eq ["(x) : String"]
    got["s.g(v)"].should eq ["(x) : String", "(x : Int32) : Char"]
  end
end
