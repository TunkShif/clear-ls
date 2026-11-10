require "json"

@[Link("m", ldflags: "-lm")]
lib LibDemo
  @[Raises]
  fun cos(x : Float64) : Float64
end

class Point
  include JSON::Serializable

  @[JSON::Field(key: "px", emit_null: true)]
  property x : Int32 = 0
end

x = 1
