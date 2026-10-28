class Item
  property name = "foo"

  def +(other : Item) : Item
    self
  end
end

item = Item.new
items = [item]
puts item.name

