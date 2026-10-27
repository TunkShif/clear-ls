require "../items"
require "./def_map"

module ClearLS::Semantics
  # Identity of one declaration: the item's index path in its file's
  # `ItemTree` (top-level index, then child indices). Stable across body
  # edits (byte ranges move, the item structure doesn't) and distinct for
  # overloads and reopenings, which are separate items.
  record DefId, file : FileId, path : Array(Int32) do
    def to_s(io : IO) : Nil
      io << file.value << ':' << path.join('.')
    end

    # The item, if *tree* still has it.
    def item_in(tree : Items::ItemTree) : Items::Item?
      list = tree.items
      item = nil.as(Items::Item?)
      path.each do |i|
        item = list[i]? || return nil
        list = item.children
      end
      item
    end

    # The id of *item* in *tree* (by identity), if it is there.
    def self.of(file : FileId, tree : Items::ItemTree, item : Items::Item) : DefId?
      path = [] of Int32
      find(tree.items, item, path) ? new(file, path) : nil
    end

    private def self.find(list : Array(Items::Item), target : Items::Item, path : Array(Int32)) : Bool
      list.each_with_index do |it, i|
        path << i
        return true if it.same?(target) || find(it.children, target, path)
        path.pop
      end
      false
    end
  end
end
