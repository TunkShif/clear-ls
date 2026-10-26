require "./h"
a = 1
if cond
  a = "hello"
else
  a = true
end
__t(a)
b = 1
b = "hello" if cond
__t(b)
if cond
  d = 1
end
__t(d)
x = cond ? nil : 3
if x
  __t(x)
end
__t(x)
if x.nil?
  __t(x)
else
  __t(x)
end
y = cond ? 1 : "s"
if y.is_a?(Int32)
  __t(y)
else
  __t(y)
end
if y.responds_to?(:upcase)
  __t(y)
end
unless x
  __t(x)
end
if !x
  __t(x)
end
z = cond ? nil : "s"
if x && z
  __t(x)
  __t(z)
end
if x.nil? || z.nil?
else
  __t(z)
end
if v = x
  __t(v)
end
__t(x ? 1 : "a")
__t(x || "fallback")
__t(x && "y")
__t(!x)
w = 1
while cond
  __t(w) # cls: (Int32 | String)  compiler prints each loop iteration
  w = "hello"
  __t(w)
end
__t(w)
u = 1
until cond
  u = 'c'
end
__t(u)
c = 1
r = while c < 5
  c += 1
  break "four" if c == 4
  break 3 if c == 3
end
__t(r)
r2 = while true
  break 1
end
__t(r2)
r3 = while cond
  break 3, 4
end
__t(r3)
e = 1
if cond
  e = "s"
else
  raise "x"
end
__t(e)
