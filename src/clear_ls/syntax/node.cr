require "./grammar"
require "../base/text_range"
require "../base/line_index"

module ClearLS::Syntax
  # A Tree-sitter node bound to the tree that owns it.
  #
  # Holding the `Tree` keeps the native tree alive for as long as any node is
  # reachable. Nodes are plain values; equality is node identity.
  struct Node
    getter raw : LibTreeSitter::TSNode
    getter tree : Tree

    def initialize(@raw, @tree)
    end

    # Returns *value* after keeping the owning tree reachable, so a native
    # call that produced *value* cannot race the tree's finalizer.
    @[AlwaysInline]
    private def alive(value : T) : T forall T
      Syntax.keep_alive(@tree)
      value
    end

    def self.wrap?(raw : LibTreeSitter::TSNode, tree : Tree) : Node?
      LibTreeSitter.ts_node_is_null(raw) ? nil : new(raw, tree)
    end

    def kind : Kind
      Grammar.kind(symbol)
    end

    def symbol : UInt16
      alive(LibTreeSitter.ts_node_symbol(@raw).unsafe_as(UInt16))
    end

    # Grammar type string, e.g. `"method_def"` or `"("`.
    def type : String
      alive(String.new(LibTreeSitter.ts_node_type(@raw)))
    end

    def named? : Bool
      alive(LibTreeSitter.ts_node_is_named(@raw))
    end

    def error? : Bool
      alive(LibTreeSitter.ts_node_is_error(@raw))
    end

    def missing? : Bool
      alive(LibTreeSitter.ts_node_is_missing(@raw))
    end

    def extra? : Bool
      alive(LibTreeSitter.ts_node_is_extra(@raw))
    end

    def has_error? : Bool
      alive(LibTreeSitter.ts_node_has_error(@raw))
    end

    def start_byte : UInt32
      alive(LibTreeSitter.ts_node_start_byte(@raw))
    end

    def end_byte : UInt32
      alive(LibTreeSitter.ts_node_end_byte(@raw))
    end

    def range : TextRange
      TextRange.new(start_byte, end_byte)
    end

    def text : String
      @tree.text.byte_slice(start_byte, end_byte - start_byte)
    end

    def parent : Node?
      Node.wrap?(LibTreeSitter.ts_node_parent(@raw), @tree)
    end

    def child_count : Int32
      alive(LibTreeSitter.ts_node_child_count(@raw).to_i32)
    end

    def named_child_count : Int32
      alive(LibTreeSitter.ts_node_named_child_count(@raw).to_i32)
    end

    def child(index : Int) : Node?
      return nil unless 0 <= index < child_count
      Node.wrap?(LibTreeSitter.ts_node_child(@raw, index.to_u32), @tree)
    end

    def named_child(index : Int) : Node?
      return nil unless 0 <= index < named_child_count
      Node.wrap?(LibTreeSitter.ts_node_named_child(@raw, index.to_u32), @tree)
    end

    def children : Array(Node)
      Array(Node).new(child_count) { |i| child(i).not_nil! }
    end

    def named_children : Array(Node)
      Array(Node).new(named_child_count) { |i| named_child(i).not_nil! }
    end

    # First *named* child stored under *field*.
    #
    # The grammar also tags punctuation with fields (`type: ":"`,
    # `default: "="`), so the raw first child is often not the useful one.
    def field(field : Field) : Node?
      first = Node.wrap?(LibTreeSitter.ts_node_child_by_field_id(@raw, Grammar.field_id(field).unsafe_as(LibTreeSitter::TSFieldId)), @tree)
      return first if first.nil? || first.named?
      fields(field).find(&.named?)
    end

    # Text of `field(field)`, if present.
    def field_text(field : Field) : String?
      field(field).try(&.text)
    end

    # All children stored under *field* (some fields repeat).
    def fields(field : Field) : Array(Node)
      result = [] of Node
      each_child_with_field { |node, f| result << node if f == field }
      result
    end

    # Yields every child and the field it is stored under (`Field::None` if any).
    def each_child_with_field(& : Node, Field ->) : Nil
      cursor = LibTreeSitter.ts_tree_cursor_new(@raw)
      begin
        if LibTreeSitter.ts_tree_cursor_goto_first_child(pointerof(cursor))
          loop do
            node = Node.new(LibTreeSitter.ts_tree_cursor_current_node(pointerof(cursor)), @tree)
            fid = LibTreeSitter.ts_tree_cursor_current_field_id(pointerof(cursor)).unsafe_as(UInt16)
            yield node, Grammar.field(fid)
            break unless LibTreeSitter.ts_tree_cursor_goto_next_sibling(pointerof(cursor))
          end
        end
      ensure
        LibTreeSitter.ts_tree_cursor_delete(pointerof(cursor))
        Syntax.keep_alive(@tree)
      end
    end

    def next_sibling : Node?
      Node.wrap?(LibTreeSitter.ts_node_next_sibling(@raw), @tree)
    end

    def prev_sibling : Node?
      Node.wrap?(LibTreeSitter.ts_node_prev_sibling(@raw), @tree)
    end

    # Smallest node spanning `[start, end)`; `named` restricts to named nodes.
    def descendant(start : UInt32, stop : UInt32 = start, *, named : Bool = false) : Node?
      raw = if named
              LibTreeSitter.ts_node_named_descendant_for_byte_range(@raw, start, stop)
            else
              LibTreeSitter.ts_node_descendant_for_byte_range(@raw, start, stop)
            end
      Node.wrap?(raw, @tree)
    end

    # Pre-order walk. Return `false` from the block to skip a node's children.
    def walk(& : Node -> Bool?) : Nil
      cursor = LibTreeSitter.ts_tree_cursor_new(@raw)
      begin
        depth = 0
        loop do
          node = Node.new(LibTreeSitter.ts_tree_cursor_current_node(pointerof(cursor)), @tree)
          descend = (yield node) != false
          if descend && LibTreeSitter.ts_tree_cursor_goto_first_child(pointerof(cursor))
            depth += 1
            next
          end
          loop do
            return if depth == 0
            break if LibTreeSitter.ts_tree_cursor_goto_next_sibling(pointerof(cursor))
            LibTreeSitter.ts_tree_cursor_goto_parent(pointerof(cursor))
            depth -= 1
          end
        end
      ensure
        LibTreeSitter.ts_tree_cursor_delete(pointerof(cursor))
        Syntax.keep_alive(@tree)
      end
    end

    # Tree-sitter's S-expression form (named nodes and fields).
    def sexp : String
      ptr = LibTreeSitter.ts_node_string(@raw)
      String.new(ptr)
    ensure
      Syntax.free_native(ptr.as(Void*)) if ptr
      Syntax.keep_alive(@tree)
    end

    # First and last line (zero-based) the node spans.
    def lines : {UInt32, UInt32}
      index = @tree.line_index
      {index.line_of(start_byte), index.line_of(end_byte)}
    end

    def ==(other : Node) : Bool
      alive(LibTreeSitter.ts_node_eq(@raw, other.raw))
    end

    def inspect(io : IO) : Nil
      io << "Node(" << type << ' ' << range << ')'
    end

    def to_s(io : IO) : Nil
      inspect(io)
    end
  end
end
