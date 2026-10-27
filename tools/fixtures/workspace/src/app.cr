require "./shapes"

def area_of(s : Shape) : Int32
  s.area
end

sq = Square.new(2)
puts sq.area, area_of(sq), sq.label
c = Circle.new
puts c.area
