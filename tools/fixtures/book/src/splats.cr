require "./h"
# splats_and_tuples.md, default_values_named_arguments_splats_tuples_and_overloading.md,
# literals/array.md, literals/tuple.md (splat expansion), assignment.md
# G4: splat params inside the body
def sum(*elements)
  __t(elements) # cls: Tuple  inside the def: one compiler type per call, clear-ls shows the def alone
  elements
end
__t(sum 1, 2, 3)
__t(sum 1, 2.5)
__t(sum)
def opts(x, **other)
  __t(other) # cls: NamedTuple  inside the def: one compiler type per call
  other
end
__t(opts 1, y: 2, z: "s")
__t(opts 1)
def mixed(a, *rest, key = 0, **kw)
  {rest, kw}
end
__t(mixed(1, 2, "s", key: 1, extra: 'c'))
# G1: restricted splats
def splat_r(*xs : Int32)
  xs
end
__t(splat_r(1, 2))
def splat_u(*xs : Int32 | String)
  xs
end
__t(splat_u(1, "s"))
# G5: splatted arguments
def add2(x, y)
  x + y
end
tup = {1, 2}
__t(add2(*tup))
nt = {y: 3, x: 10}
__t(add2(**nt))
def first_of(x : Int32, y : String)
  y
end
__t(first_of(*{1, "s"}))
# G2, G6: splats in literals
coll = [1.5]
__t([1, *coll])
t1 = {"a", 'b'}
__t({1, *t1})
t2 = {"x", :y}
__t({*t2, 1})
__t(Set{1, *coll})
# G3: multi-assign with splat
q2, *rest = 1, "a", 'c'
__t(q2)
__t(rest)
*init, last = 1, "a", 'c'
__t(init)
__t(last)
a, *b, c = {1, 2.5, "s", 'c'}
__t(b)
__t(c)
x1, x2 = {1, "s"}
__t(x2)
