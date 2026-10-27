abstract class Shape
  abstract def area : Int32

  def label : String
    "shape"
  end
end

class Square < Shape
  def initialize(@side : Int32)
  end

  def area : Int32
    @side * @side
  end
end

class Circle < Shape
  def area : Int32
    3
  end
end
