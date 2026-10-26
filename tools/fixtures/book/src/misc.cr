require "./h"
x = 1
foo_blk = ->{ x = "hello" }
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
a = begin
  1
rescue
  "s"
end
__t(a)
b = (Int32.new("x") rescue nil)
__t(b)
begin
  c = 1
  raise "x"
rescue ex
  __t(ex)
  __t(c)
end
begin
rescue ex2 : ArgumentError | KeyError
  __t(ex2)
end
d = begin
  1
rescue
  "s"
else
  'c'
ensure
  :sym
end
__t(d)
def m_rescue
  1
rescue
  "s"
end
__t(m_rescue)
t = {1, "a", 'c'}
__t(t[0])
__t(t[1])
q, r = t
__t(q)
__t(r)
q2, *rest = 1, "a", 'c'
__t(rest)
s, s2 = 1, "s"
__t(s2)
h = {"a" => 1}
__t(h["a"])
__t(h["a"]?)
arr = [1, 2]
__t(arr[0])
__t(arr[0]?)
__t(arr[0..1])
o = nil.as(Int32?)
o ||= 3
__t(o)
cnt = 1
cnt += 2.0
__t(cnt)
ar2 = [1]
ar2[0] += 1
__t(ar2)
i = 1
i = i.succ
__t(i)
k = -i
__t(k)
__t(~i)
__t(i ** 2)
__t(i / 2)
__t(i // 2)
__t(i <=> 2)
__t(1 + 2.0)
__t("a" * 3)
__t(i &+ 1)
__t(i.to_s)
__t(i == 1)
__t(i < 2 ? :a : nil)
__t(!!i)
str = "s"
__t(str =~ /a/)
__t(str.size)
if str =~ /(a)/
  __t($~)
  __t($1)
end
sel = select
when vv = Channel(Int32).new.receive?
  vv
end
__t(sel)
__t(spawn { })
__t(loop { break 1 })
__t(1.tap { })
__t(1.try { |v| v.to_s })
__t(nil.try { |v| 1 })
__t(::Int32)
class Outer
  class Inner; end
  def make; Inner.new; end
end
__t(Outer.new.make)
__t(Outer::Inner.new)
CONST = [1, 2]
__t(CONST)
module M2
  V = "s"
  class K
    def v; V; end
  end
end
__t(M2::K.new.v)
__t(Int32::MAX)
__t(Float64::INFINITY)
@[Flags]
enum Perm
  Read
  Write
end
__t(Perm::Read | Perm::Write)
__t(Perm::Read.read?)
__t(Perm::Read.value)
enum Big : UInt8
  A = 1
end
__t(Big::A.value)
__t(Perm.values)
lib C
  struct S
    a : Int32
  end
  union U
    i : Int32
    f : Float64
  end
  type Handle = Void*
  alias Size = UInt64
  $errno : Int32
  fun strlen(s : UInt8*) : C::Size
  enum E
    X = 1
  end
end
sv = C::S.new
__t(sv.a)
__t(C::U.new.f)
__t(C.strlen("a"))
__t(C.errno)
__t(C::E::X)
proc = ->(cb : Int32) { cb }
__t(proc.call(1))
