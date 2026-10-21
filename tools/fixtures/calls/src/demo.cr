abstract class Shape
  abstract def area : Float64
end

class Square < Shape
  def initialize(@side : Float64)
  end

  def area : Float64
    @side * @side
  end
end

def run(io : IO, value, shapes : Array(Shape))
  a = io.gets(10)
  b = io.gets(value)
  c = shapes.map(&.area)
  d = "a,b".split(",", remove_empty: true)
  total = shapes.sum(&.area)
  io.gets()
end
