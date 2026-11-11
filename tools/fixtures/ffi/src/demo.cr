require "c/string"

@[Link("m")]
lib LibDemo
  # Cosine of *x* radians.
  fun cos(x : Float64) : Float64
  fun printf(fmt : UInt8*, ...) : Int32
  $errno : Int32

  struct Point
    x : Int32
    y : Int32
  end
end

def run
  a = LibDemo.cos(1.0)
  len = LibC.strlen("abc")
  raw = Pointer(Void).null
  pt = LibDemo::Point.new
  pt.y = sizeof(Int32)
  LibDemo.printf("%d", len)
end

x = 1
