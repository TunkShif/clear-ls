require "./lower"

module ClearLS::Items
  # Human-readable dump of an item tree, used by `clear-ls dump-items` and
  # snapshot specs.
  module Dump
    def self.dump(tree : ItemTree, line_index : LineIndex, io : IO) : Nil
      tree.requires.each do |r|
        io << "require " << r.path.inspect
        r.conditions.each { |c| io << " if " << c }
        io << '\n'
      end
      tree.items.each { |i| dump_item(i, line_index, 0, io) }
      io << "(recovered from parse errors)\n" if tree.recovered
    end

    def self.dump_item(item : Item, line_index : LineIndex, depth : Int32, io : IO) : Nil
      io << "  " * depth
      io << item.visibility.to_s.downcase << ' ' unless item.visibility.public?
      io << item.kind.to_s.downcase << ' '
      if h = item.header
        io << "::" if h.global
        io << h.path.join("::")
        unless h.type_params.empty?
          io << '('
          h.type_params.each_with_index { |p, i| io << ", " if i > 0; io << '*' if i == h.splat_index; io << p }
          io << ')'
        end
        io << " < " << h.superclass if h.superclass
        io << " : " << h.base_type if h.base_type
        io << " [abstract]" if h.is_abstract
      else
        if s = item.signature
          io << "abstract " if s.is_abstract
          io << s.receiver << '.' if s.receiver
          io << item.name
          io << " = " << s.real_name if s.real_name
          s.to_s(io)
        else
          io << item.name
          io << " : " << item.detail if item.detail
        end
      end
      io << " @" << line_index.point(item.name_range.start)
      io << " [macro]" if item.origin.macro?
      item.annotations.each { |a| io << " @[" << a << ']' }
      item.conditions.each { |c| io << " if " << c }
      io << " include " << item.includes.join(", ") unless item.includes.empty?
      io << " extend " << item.extends.join(", ") unless item.extends.empty?
      io << " doc=" << item.doc.inspect if item.doc
      io << '\n'
      item.children.each { |c| dump_item(c, line_index, depth + 1, io) }
    end
  end
end
