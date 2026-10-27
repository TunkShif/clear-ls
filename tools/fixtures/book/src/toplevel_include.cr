require "./h"
# Top-level `include` (the program includes the module): types, constants
# and instance methods of Outer are visible everywhere; class methods are
# not. Top-level declarations shadow included ones; the last include
# wins. The file starts with a module, so top-level code must not be
# analysed inside it.
module Outer
  VALUE = 42

  class Thing
    def size : Int32
      1
    end
  end

  module Inner
    class Deep
    end
  end

  def helper : String
    "h"
  end

  def shadowed : String
    "outer"
  end
end

module Later
  def shadowed : Symbol
    :later
  end

  def last : Char
    'l'
  end
end

module Earlier
  def last : Float64
    1.0
  end
end

include Outer
include Earlier
include Later

def shadowed : Int32
  1
end

__t(Thing.new)
__t(VALUE)
__t(Inner::Deep.new)
__t(helper)
__t(shadowed)
__t(last)

def in_def
  __t(Thing.new.size)
  __t(VALUE)
  __t(helper)
end

in_def

class Unrelated
  CONST = Thing

  def m
    __t(Thing.new)
    __t(helper)
  end
end

__t(Unrelated::CONST)
Unrelated.new.m

module Ns
  class Thing
  end

  def self.n
    # Enclosing namespace first, then the program's includes.
    __t(Thing.new)
  end
end

Ns.n
