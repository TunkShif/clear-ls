require "./h"
# while.md, break.md, next.md, blocks_and_procs.md (break)
a = 0
w1 = while a < 5
  a += 1
  break "four" if a == 4
  break 3 if a == 3
end
__t(w1)
w2 = while true
  break 1
end
__t(w2)
w3 = while cond
  break 3, 4
end
__t(w3)
w4 = while cond
  break
end
__t(w4)
w5 = until false
  break 'c'
end
__t(w5)
w6 = until cond
  break 'c' if cond
end
__t(w6)
l1 = loop do
  break 1 if cond
end
__t(l1)
l2 = [1, 2].each { |x| break "s" if x > 1 }
__t(l2)
l3 = [1, 2].map { |x| break "s" if x > 1; x }
__t(l3)
l4 = [1, 2].find { |x| break nil if x > 5; x > 1 }
__t(l4)
l5 = 3.times { |i| break i if i > 1 }
__t(l5)
l6 = [1].each do |x|
  [2].each { |y| break "inner" }
  break 1.5
end
__t(l6)
l7 = while cond
  [1].each { |x| break "inner" }
  break 2
end
__t(l7)
n1 = [1, 2].map { |x| next "s" if x > 1; x }
__t(n1)
b = 0
while true
  b += 1
  break if b > 3
end
__t(b)
def forever
  w7 = while true
    puts "x"
  end
  __t(w7) # cls: NoReturn  unreachable: the compiler never types it
end
__t(forever) # cls: NoReturn  not instantiated by the compiler
