class Point
  def initialize(@x : Int32)
  end

  def x : Int32
    @x
  end
end

def find(n : Int32) : Point?
  n > 0 ? Point.new(n) : nil
end

p = Point.new(1)
maybe = find(2)
label = p.x.to_s

class Messy
    def a
      x   =   1
      x+2
    end

  def b( y )
    y*2
  end
end
