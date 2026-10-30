require "dep"

class Widget
  def tool_only : String
    Dep.v2
  end
end

t = Widget.new.tool_only
puts t.tool_error
