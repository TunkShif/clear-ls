require "./h"
# enum.md, c_bindings/enum.md
enum Color
  Red
  Green = 5
  Blue

  def warm?
    __t(self)
    __t(Red)
    self == Red
  end
end
Color::Red.warm?
@[Flags]
enum Perm : UInt8
  Read
  Write
end
__t(Color::Red)
__t(Color::Green)
__t(Color::Red.value)
__t(Perm::Read.value)
__t(Color.new(1))
__t(Color.values)
__t(Color.names)
__t(Color.parse("red"))
__t(Color.parse?("red"))
__t(Color.from_value(1))
__t(Color::Red.to_s)
__t(Color::Red == Color::Blue)
__t(Color::Red.red?)
__t(Color::Red + 1)
__t(Perm::Read | Perm::Write)
__t(Perm::None)
__t(Perm::All)
__t(~Perm::Read)
__t((Perm::Read | Perm::Write).includes?(Perm::Read))
__t(Perm::Read.write?)
DEFAULT = Color::Blue
__t(DEFAULT)
def pick(c : Color); c; end
__t(pick(:green))
c = cond ? Color::Red : Color::Blue
case c
in .red?
  __t(c)
in Color::Green, Color::Blue
  __t(c)
end
module Outer
  enum Inner
    A
  end
  def self.get; Inner::A; end
end
__t(Outer.get)
__t(Outer::Inner::A)
