require "./h"
# if_varresponds_to.md, case.md (tuple literal, assignment), while.md
y = cond ? 1 : "s"
if y.responds_to?(:upcase)
  __t(y)
else
  __t(y)
end
while y.responds_to?(:abs)
  __t(y)
  break
end
p1 = cond ? 1 : "s"
p2 = cond ? 'c' : nil
case {p1, p2}
when {String, Char}
  __t(p1)
  __t(p2)
when {Int32, _}
  __t(p1)
  __t(p2)
end
case {p1, p2}
when {.is_a?(Int32), .nil?}
  __t(p1)
end
case num = cond ? 1 : nil
when Int32
  __t(num)
when nil
  __t(num)
end
case n2 = p1
when String
  __t(n2)
end
