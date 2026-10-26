require "./h"
class Foo; end
class Bar < Foo; end
class Baz < Foo; end
abstract class Animal; end
class Dog < Animal; end
class Cat < Animal; end
foo = cond ? Bar.new : Baz.new
__t(foo) # cls: (Bar | Baz)  decision 1: exact unions; lookup falls back to the parent
pet = cond ? Dog.new : Cat.new
__t(pet) # cls: (Cat | Dog)  decision 1
t1 = {1, "hi"}
t2 = {true, nil}
t3 = cond ? t1 : t2
__t(t3) # cls: (Tuple(Bool, Nil) | Tuple(Int32, String))  decision 2: indexing gives per-position unions
n1 = {x: 1, y: "hi"}
n2 = {y: true, x: nil}
n3 = cond ? n1 : n2
__t(n3) # cls: (NamedTuple(x: Int32, y: String) | NamedTuple(y: Bool, x: Nil))  decision 2
a = 0.as(Int32 | Nil | String)
__t(a)
__t(a.to_s)
i = cond ? 1 : 2_i64
__t(i)
__t(cond ? 1 : 1.5)
s = cond ? "a" : :b
__t(s.to_s)
__t(Dog.new.as(Animal))
__t(pet.as?(Dog))
__t(a.as?(String))
__t(typeof(a))
__t(Int32 | String)
__t(Dog)
__t(Dog.new.class)
__t(pet.class) # cls: (Cat.class | Dog.class)  decision 1
__t(Int32?)
