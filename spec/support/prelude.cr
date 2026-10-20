# Minimal stdlib stand-in: enough declarations for inference specs without
# depending on the installed compiler.
PRELUDE = <<-CR
  class Object
    def to_s : String
    end
    def inspect : String
    end
    def try(& : self -> U) forall U
    end
  end
  class Reference; end
  struct Value; end
  struct Struct; end
  struct Nil
    def to_s : String
    end
  end
  struct Bool; end
  struct Char; end
  struct Symbol; end
  struct Int32
    def +(other : Int32) : Int32
    end
    def times(& : Int32 ->) : Nil
    end
    def to_s : String
    end
    def abs : Int32
    end
  end
  struct Int64
    def +(other : Int64) : Int64
    end
  end
  struct UInt8; end
  struct Float64; end
  struct Float32; end
  class String
    def size : Int32
    end
    def upcase : String
    end
    def +(other : String) : String
    end
    def chars : Array(Char)
    end
    def split(sep : String) : Array(String)
    end
  end
  class Regex; end
  module Enumerable(T)
    def map(& : T -> U) : Array(U) forall U
    end
    def first : T
    end
    def first? : T?
    end
    def each_with_index(& : T, Int32 ->)
    end
  end
  module Indexable(T)
    include Enumerable(T)
    def [](index : Int) : T
    end
  end
  class Array(T)
    include Indexable(T)
    def each(& : T ->) : Nil
    end
    def <<(value : T) : self
    end
    def size : Int32
    end
    def self.new(size : Int, value : T)
    end
  end
  class Hash(K, V)
    include Enumerable({K, V})
    def [](key : K) : V
    end
    def keys : Array(K)
    end
    def each(& : {K, V} ->) : Nil
    end
  end
  struct Tuple(*T); end
  struct NamedTuple(**T); end
  struct Range(B, E); end
  struct Pointer(T); end
  struct Proc(*T); end
  class Set(T)
    include Enumerable(T)
  end
  class IO
    def gets : String?
    end
    def puts(*objects) : Nil
    end
  end
  CR

# The prelude split into stdlib-like files for feature specs.
PRELUDE_FILES = {
  "object.cr"     => PRELUDE.split("module Enumerable(T)")[0],
  "enumerable.cr" => "module Enumerable(T)" + PRELUDE.split("module Enumerable(T)")[1],
}
