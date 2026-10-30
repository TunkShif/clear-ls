require "dep"

class Widget
  def app_only : Int32
    Dep.v1
  end
end

w = Widget.new.app_only
puts w.app_error
