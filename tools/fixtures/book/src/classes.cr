require "./h"
class Person
  @age = 0
  @@count = 0
  def initialize(@name : String, nick = "x")
    @nick = nick
    @addr = Address.new
    @vals = Array(Int32).new
    @lucky = nil.as(Int32?)
  end
  def lucky
    @lucky_number = 42
  end
  def show
    __t(@name)
    __t(@age)
    __t(@nick)
    __t(@addr)
    __t(@vals)
    __t(@lucky_number)
    __t(@@count)
    __t(@from_cm)
    __t(@from_lib) # cls: ?  ivar rule 6 (lib fun result) is left to compiler facts (decision 5)
    __t(@out_v) # cls: ?  ivar rule 7 (out) is left to compiler facts (decision 5)
    __t(self)
  end
  def init2(obj : Int64)
    @p3 = obj
    @from_cm = Address.make
    @from_lib = LibX.compute
    LibX.get(out @out_v)
  end
  def p3
    __t(@p3)
    @p3
  end
  def self.create
    __t(self)
    new("a")
  end
end
class Address
  def self.make
    new
  end
end
lib LibX
  fun compute : Int32
  fun get(x : Float64*) : Void
end
pp = Person.new("a")
pp.show
pp.p3
__t(Person.create)
__t(Person.new("a"))
class MyBox(T)
  def initialize(@value : T); end
  def value; @value; end
  def self.nilable(x : U) forall U
    MyBox(U?).new(x)
  end
end
__t(MyBox.new(1))
__t(MyBox.new(1).value)
__t(MyBox(String).new("s"))
__t(MyBox.nilable(1))
class IntMyBox < MyBox(Int32); end
__t(IntMyBox.new(1).value)
module Greet
  def greet; "hi"; end
end
class G; include Greet; end
__t(G.new.greet)
module Util
  extend self
  def twice(x); x * 2; end
end
__t(Util.twice(2))
struct Point
  property x : Int32 = 0
  getter y : Int32?
  getter! z : String
  property? ok : Bool = false
end
po = Point.new
__t(po.x)
__t(po.y)
__t(po.z)
__t(po.ok?)
record Rec, a : Int32, b : String
__t(Rec.new(1, "a").b)
class Parent
  def foo; 1; end
  def bar(x : Int32); "p"; end
end
class Child < Parent
  def foo; super.to_s; end
  def foo(x); 'c'; end
end
__t(Child.new.foo)
__t(Child.new.bar(1))
class Redef
  def m; 1; end
  def m; previous_def.to_f; end
end
__t(Redef.new.m)
alias Num = Int32 | Float64
nn : Num = 1
__t(nn)
alias IntP = Pointer(Int32)
__t(IntP.malloc(1))
n2 : Int32? = nil
__t(n2)
u = uninitialized Int32
__t(u)
x = 1
__t(pointerof(x))
__t(sizeof(Int32))
__t(instance_sizeof(Person))
__t(alignof(Int64))
__t(offsetof(Point, @x))
__t(typeof(1, "a"))
__t(x.unsafe_as(Float32))
__t(Pointer(Int32).null)
__t(pointerof(x).value)
__t(x.responds_to?(:abs))
__t(x.is_a?(Int32))
__t(x.nil?)
__t(Person.new("a").class)
__t(Int32.class)
__t(Person.name)
