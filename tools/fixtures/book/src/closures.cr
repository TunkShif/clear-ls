require "./h"
# closures.md, methods_and_instance_variables.md (previous_def),
# inheritance.md (super), generics.md, class_methods.md
# H1: captured locals
x = 1
pr = -> { x = "hello" }
x = 'a'
__t(x)
def capture(&block)
  block
end
y = 1
capture { y = "s" }
y = 'a'
__t(y)
def foo(&)
  yield
end
z = 1
foo { z = "h" }
__t(z)
z = 'a'
__t(z)
w = 1
cnt = -> { w += 1; w }
__t(w)
__t(cnt.call)
# I1: previous_def
class Redef
  def m; 1; end
  def m; previous_def.to_f; end
  def n(x : Int32); "i"; end
  def n(x : Int32); previous_def + "!"; end
  def k; 'c'; end
end
__t(Redef.new.m)
__t(Redef.new.n(1))
class Redef
  def k; :sym; end
end
__t(Redef.new.k)
# I2: super
class Parent
  def foo; 1; end
  def bar(x : Int32); "p"; end
  def baz(x); [x]; end
end
class Child < Parent
  def foo; super.to_s; end
  def bar(x : Int32); super(x).size; end
  def baz(x); super; end
end
__t(Child.new.foo)
__t(Child.new.bar(1))
__t(Child.new.baz('c'))
# I3: generic args from initialize
class MyBox(T)
  def initialize(@value : T); end
  def value; @value; end
end
__t(MyBox.new(1))
__t(MyBox.new(1).value)
__t(MyBox.new("s").value)
class Pair(A, B)
  def initialize(@a : A, @b : B); end
  def b; @b; end
end
__t(Pair.new(1, "s"))
__t(Pair.new(1, "s").b)
class Wrap(T)
  def initialize(x : Array(T)); end
end
__t(Wrap.new([1.5]))
# I4: new inside class methods
class Person
  def initialize(@name : String); end
  def self.create
    new("a")
  end
  def self.make2 : self
    new("b")
  end
  def self.other
    create
  end
end
__t(Person.create)
__t(Person.make2)
__t(Person.other)
