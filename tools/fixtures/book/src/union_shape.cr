require "./h"
# union_types.md, virtual_and_abstract_types.md: union-shape decisions 1-4, 6
abstract class Animal
  abstract def talk
  def name : String; "a"; end
end
class Dog < Animal
  def talk; "w"; end
end
class Cat < Animal
  def talk; :m; end
end
def speak(a : Animal)
  __t(a.talk) # cls: (String | Symbol)  the def analysed for any Animal (compiler: per instantiation)
  __t(a.name)
end
speak(Dog.new)
pet = cond ? Dog.new : Cat.new
__t(pet.talk)
t3 = cond ? {1, "hi"} : {true, nil}
__t(t3[0])
__t(t3[1])
q, r = t3
__t(q)
__t(r)
n3 = cond ? {x: 1, y: "hi"} : {y: true, x: nil}
__t(n3[:x])
alias Num = Int32 | Float64
nn : Num = 1
__t(nn) # cls: Int32  flow type here (compiler also prints the loop-free declared type)
nn = 2.5
__t(nn)
n2 : Int32? = nil
__t(n2)
__t(Int32 | String)
__t(Int32?)
__t(String | Nil)
