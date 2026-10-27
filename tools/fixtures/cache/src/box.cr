class Box
  {% for n in %w(width height) %}
    def {{n.id}} : Int32
      1
    end
  {% end %}

  def label : String
    "box"
  end
end
