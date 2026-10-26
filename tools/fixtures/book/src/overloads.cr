require "./h"
enum Big : UInt8
  A = 1
  B
end
__t(Big::A)
__t(Big::B)
def foo(*elements, x); 1; end
def foo(*elements, y); "s"; end
__t(foo x: "a")
__t(foo y: "a")
def ov(x : Int32); 1; end
def ov(x : Float64); "f"; end
__t(ov(1))
__t(ov(1.5))
def ov2(x : Number); 1; end
def ov2(x : Int32); "i"; end
__t(ov2(1))
def ov3(x : Int64); 1; end
__t(ov3(1))
class A1; def m; 1; end; end
class B1 < A1; def m; "b"; end; end
v = cond ? A1.new : B1.new
__t(v.m)
def tr(x : Int32?) ; x; end
__t(tr(nil))
def zz(*, a : Int32 = 1); a; end
__t(zz)
def bl(&block : Int32 -> Int32); block; end
f = bl { |x| x }
__t(f.call(1))
__t(Proc(Int32, Int32))
