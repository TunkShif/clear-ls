require "./h"
# autocasting.md, checked against Crystal 1.22.
def i64(x : Int64); x; end
def u8(x : UInt8); x; end
def f64(x : Float64); x; end
def f32(x : Float32); x; end
a = 1
b = 1_u8
c = 1_f32
d = 1_i16
e = 1_u32
__t(i64(a))
__t(i64(b))
__t(i64(e))
__t(f64(a))
__t(f64(c))
__t(f64(d))
__t(f32(d))
__t(u8(255))
__t(f32(1))
__t(f32(1.5))
# An exact match beats a cast; an untyped param is exact.
def o1(x : Int64); 1; end
def o1(x); "s"; end
__t(o1(1))
__t(o1(a))
def o2(x : Int64); 1; end
def o2(x : Float32); "s"; end
__t(o2(a))
def o3(x : Int32); 1; end
def o3(x); 'c'; end
__t(o3(1.5))
__t(o3(1))
def o4(x : Int32 | String); 1; end
__t(o4(1_i8))
n = 1
n += 2.0
__t(n)
__t(2 ** 2)
__t(2 ** 2.0)
