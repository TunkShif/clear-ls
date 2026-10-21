module Plug
  macro included
    def plugged : String; "yes"; end
  end
end

class Square
  include Plug
  {% for n in %w(width height) %}
    def {{n.id}} : Int32; 2; end
  {% end %}
  getter name : String = "sq"

  def initialize
    @label = "square"
  end

  def area
    @label.size * width
  end
end
