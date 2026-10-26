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
    @[Primitive(:class)]
    def class
    end
  end
  class Class
    def name : String
    end
  end
  class Reference; end
  struct Value; end
  struct Enum
    def to_s : String
    end
  end
  struct Struct; end
  abstract struct Number; end
  abstract struct Int < Number; end
  abstract struct Float < Number; end
  struct Nil
    def to_s : String
    end
  end
  struct Bool; end
  struct Char; end
  struct Symbol; end
  struct Int32 < Int
    def +(other : Int32) : Int32
    end
    def times(& : Int32 ->) : Nil
    end
    def to_s : String
    end
    def abs : Int32
    end
  end
  struct Int64 < Int
    def +(other : Int64) : Int64
    end
  end
  struct UInt8 < Int; end
  struct Int16 < Int; end
  struct UInt64 < Int; end
  struct Float64 < Float; end
  struct Float32 < Float; end
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
  struct Pointer(T)
    @[Primitive(:pointer_malloc)]
    def self.malloc(size : UInt64)
    end
    def self.malloc(size : Int = 1)
      malloc(size.to_u64)
    end
  end
  struct Proc(*T); end
  class Set(T)
    include Enumerable(T)
  end
  class IO
    def gets(chomp : Bool = true) : String?
    end
    def gets(limit : Int, chomp : Bool = false) : String?
    end
    def gets(delimiter : Char, chomp : Bool = false) : String?
    end
    def gets(delimiter : Char, limit : Int, chomp = false) : String?
    end
    def gets(delimiter : String, chomp = false) : String?
    end
    def puts(*objects) : Nil
    end
  end
  class Exception
    def message : String?
    end
  end
  class IO::Error < Exception; end
  def raise(message : String) : NoReturn
  end
  CR

# The prelude split into stdlib-like files for feature specs.
PRELUDE_FILES = {
  "object.cr"     => PRELUDE.split("module Enumerable(T)")[0],
  "enumerable.cr" => "module Enumerable(T)" + PRELUDE.split("module Enumerable(T)")[1],
}
