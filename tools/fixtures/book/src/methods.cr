require "./h"
def sum(*elements)
  __t(elements)
  elements
end
sum 1, 2, 3
def opts(x, **other)
  __t(other)
  other
end
opts 1, y: 2, z: "s"
def named(*, z : Int32)
  z
end
__t(named(z: 1))
tup = {1, 2}
def add2(x, y)
  x + y
end
__t(add2(*tup))
nt = {y: 3, x: 10}
__t(add2(**nt))
def dflt(x = 1, y = "a")
  {x, y}
end
__t(dflt)
__t(dflt(2.5))
__t(dflt(y: :s))
def ext(to target : Int32)
  target
end
__t(ext(to: 3))
def ret_restr : Int32 | String
  1
end
__t(ret_restr)
def nil_ret : Nil
  1
end
__t(nil_ret)
def raiser : NoReturn
  raise "x"
end
def early(x)
  return "s" if x
  1
end
__t(early(true))
def multi_ret
  return 1, "a"
end
__t(multi_ret)
def over(x : Int32); 1; end
def over(x : String); "s"; end
def over(x); 'c'; end
__t(over(1))
__t(over("a"))
__t(over(1.5))
def gen(x : T) forall T
  [x]
end
__t(gen(1))
def gen_ret(x : Array(T)) : T forall T
  x[0]
end
__t(gen_ret(["a"]))
def under(x : Array(_))
  x.size
end
__t(under([1]))
def splat_r(*xs : Int32)
  xs
end
__t(splat_r(1, 2))
def autocast(x : Int64); x; end
__t(autocast(1))
def autof(x : Float64); x; end
__t(autof(1))
enum Dir2
  Up
  Down
end
def sym_ac(d : Dir2); d; end
__t(sym_ac(:up))
__t(1.as(Int32).itself)
def blk(&)
  yield 1, "a"
end
blk do |a, b|
  __t(a)
  __t(b)
end
__t(blk { |a, b| b })
def blk_r(& : Int32 -> String)
  yield 1
end
__t(blk_r { |i| i.to_s })
def cap(&block : Int32 -> String)
  block
end
__t(cap { |i| i.to_s })
def cap2(&block : Int32 -> _)
  block
end
__t(cap2 { |i| i * 2.0 })
__t([1, 2].map(&.to_s))
__t([1, 2].map { |x| x.to_f })
pr = ->(x : Int32) { x * 2 }
__t([1].map(&pr))
__t([{1, "a"}].map { |(a, b)| b })
__t([{1, "a"}].map { |a, b| b })
__t([1].each_with_index.map { |x, i| i })
def with_y(&)
  with "str" yield
end
with_y do
  __t(upcase)
end
v = 1
v2 = [1].each { break "s" }
__t(v2)
v3 = [1].map { |x| next "s" if x > 0; 1 }
__t(v3)
def nest_yield(&)
  yield(yield 1)
end
__t(nest_yield { |x| x })
