require "./shapes"

def twice(x)
  y = x + x
  y
end

twice(1)
twice("a")

s = Square.new
w = s.width
p = s.plugged
puts w, p, s.area, s.name
s.area.nope
