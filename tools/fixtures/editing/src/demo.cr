alias Names = Array(String)

class Item
  property name = "foo"

  def +(other : Item) : Item
    self
  end

  def tags : Names
    ["a"]
  end
end

item = Item.new
items = [item]
item.name = "bar"
t = item.tags
items.each { |i| puts i.name }
puts item.name

