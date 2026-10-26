require "./h"
# type_inference.md (rules 1-7), class_variables.md, if_var.md
class Address
  def initialize(@street = "x"); end
  def self.unknown
    new("unknown")
  end
  def self.typed : Address
    new("t")
  end
end
lib LibPerson
  fun compute_default_age : Int32
  fun get_age(age : Int32*) : Void
end
class Person
  @level = 3
  @@count = 0
  @@names = [] of String
  def initialize(name : String, nick = "n", obj : Int64 = 1_i64)
    @name = name       # rule 3
    @nick = nick       # rule 5
    @obj = obj         # rule 3 (restriction wins over default)
    @age = 0           # rule 1
    @address = Address.new # rule 2
    @values = Array(Int32).new # rule 2 generic
    @unknown_addr = Address.unknown # rule 4 (body)
    @typed_addr = Address.typed # rule 4 (restriction)
    @lib_age = LibPerson.compute_default_age # rule 6
    LibPerson.get_age(out @out_age) # rule 7
    @maybe = cond ? 1.5 : nil
    @either = 1
    @either = "s" if cond
  end
  def initialize(other : Person)
    @name = "copy"
    @nick = "c"
    @obj = 2_i64
    @age = 1
    @address = Address.new
    @values = [1]
    @unknown_addr = Address.new
    @typed_addr = Address.new
    @lib_age = 1
    @out_age = 1
    @maybe = 1.0
    @either = 2
  end
  def lucky
    @lucky_number = 42 # only outside initialize
  end
  def self.bump
    @@later = 'c'
  end
  def show
    __t(@name)
    __t(@nick)
    __t(@obj)
    __t(@age)
    __t(@address)
    __t(@values)
    __t(@unknown_addr)
    __t(@typed_addr)
    __t(@lib_age) # cls: ?  rule 6 is left to compiler facts (decision 5)
    __t(@out_age) # cls: ?  rule 7 is left to compiler facts (decision 5)
    __t(@maybe)
    __t(@either)
    __t(@lucky_number)
    __t(@level)
    __t(@@count)
    __t(@@names)
    __t(@@later)
  end
end
Person.new("a").show
Person.new(Person.new("b")).show
Person.new("a").lucky
Person.bump
class Kid < Person
  def initialize
    super("k")
    @toy = "t"
  end
  def play
    __t(@toy)
    __t(@age)
  end
end
Kid.new.play
class NoInit
  def set
    @v = 1
  end
  def get
    __t(@v)
  end
end
NoInit.new.get
class Gen(T)
  def initialize(x : T)
    @x = x
  end
  def x
    __t(@x) # cls: T  generic def analysed alone; call sites substitute (line below)
    @x
  end
end
__t(Gen.new(1).x)
