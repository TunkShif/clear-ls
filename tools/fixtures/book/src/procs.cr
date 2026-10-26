require "./h"
# literals/proc.md, proc_literal.md, blocks_and_procs.md, capturing_blocks.md,
# block_forwarding.md
# F1: return annotations
__t(-> : Int32 | String { 1 })
__t(->(x : Array(String)) : Nil { x.delete("foo") })
__t(->(x : Int32) : Int64 { x.to_i64 })
__t(-> { 1 })
__t(->(x : Int32, y : Int32) { x + y })
# F3: method procs
def one
  1
end
def plus_one(x)
  x + 1
end
def typed(x : Int32) : String
  x.to_s
end
str = "hello"
__t(->one)
__t(->plus_one(Int32))
__t(->typed(Int32))
__t(->str.count(Char))
__t(->str.upcase)
__t(->Math.sqrt(Float64))
mp = ->typed(Int32)
__t(mp.call(1))
# F2: &proc
pr = ->(x : Int32) { x * 2 }
__t([1].map(&pr))
__t([1].map(&->typed(Int32)))
__t([1].each(&pr))
# F4: block restrictions with `_`
def cap(&block : Int32 -> String)
  block
end
def cap2(&block : Int32 -> _)
  block
end
def cap3(&block : -> _)
  block
end
__t(cap { |i| i.to_s })
__t(cap2 { |i| i * 2.0 })
__t(cap3 { 'c' })
__t(cap2 { |i| i.to_s }.call(1))
# captured block returns
def capture(&block)
  block
end
__t(capture { 1 })
# F5: with ... yield
class Builder
  def add(x : Int32) : Int32
    x
  end
  def build(&)
    with self yield
  end
end
def with_str(&)
  with "str" yield
end
with_str do
  __t(upcase)
  __t(size)
end
Builder.new.build do
  __t(add(1))
end
# Proc.new and call
pn = Proc(Int32, String).new { |x| x.to_s }
__t(pn)
__t(pn.call(1))
__t(pr.call(2))
__t(pr.arity)
# forwarding
def fwd(&block : Int32 -> String)
  inner(&block)
end
def inner(&block : Int32 -> String)
  block.call(1)
end
__t(fwd { |i| i.to_s })
def fwd2(&)
  [1, 2].map { |x| yield x }
end
__t(fwd2 { |x| x.to_s })
