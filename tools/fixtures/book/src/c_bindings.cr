require "./h"
# c_bindings/*.md: lib, fun, struct, union, type, alias, enum, variables,
# constants, out, to_unsafe, callbacks
@[Link("c")]
lib C
  alias Size = UInt64
  type Handle = Void*
  PI = 3
  enum Mode
    Read = 1
    Write = 2
  end
  struct Point
    x : Int32
    y : Float64
    next_ptr : Point*
  end
  union Value
    i : Int32
    f : Float64
  end
  $errno : Int32
  fun strlen(s : UInt8*) : Size
  fun puts(s : UInt8*) : Int32
  fun abs(x : Int32) : Int32
  fun get_handle : Handle
  fun get_point(p : Point*) : Void
  fun callback(cb : Int32 -> Int32) : Int32
  fun variadic = printf(fmt : UInt8*, ...) : Int32
end
__t(C.strlen("a"))
__t(C.abs(-1))
__t(C.get_handle)
__t(C.errno)
__t(C::PI)
__t(C::Mode::Read)
__t(C::Mode::Read.value)
pt = C::Point.new
__t(pt)
__t(pt.x)
__t(pt.y)
__t(pt.next_ptr)
pt.x = 3
__t(pt.x)
v = C::Value.new
__t(v.i)
__t(v.f)
C.get_point(out p2)
__t(p2)
__t(p2.y)
__t(C.callback(->(x : Int32) { x }))
__t(C.variadic("%d", 1))
__t(pointerof(pt).value.x)
__t(C::Size)
