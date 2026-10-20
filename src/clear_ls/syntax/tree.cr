require "./node"

module ClearLS::Syntax
  # A text replacement in byte offsets of the old text.
  record TextEdit, range : TextRange, new_text : String do
    def self.insert(offset : UInt32, text : String) : self
      new(TextRange.empty(offset), text)
    end

    def self.delete(range : TextRange) : self
      new(range, "")
    end

    def apply(text : String) : String
      bytes = text.to_slice
      String.build(text.bytesize - range.size + new_text.bytesize) do |io|
        io.write(bytes[0, range.start])
        io << new_text
        io.write(bytes[range.end..])
      end
    end
  end

  # An immutable parse of one text revision.
  #
  # Owns the native tree, its source text, and the line index used to
  # compute Tree-sitter points. Never mutated after construction; edits make
  # a new `Tree` (`Parser#reparse`). Sharing across fibers is safe for reads;
  # use `#copy` before handing the tree to another thread.
  class Tree
    getter text : String
    getter line_index : LineIndex
    # Byte ranges (in this text) whose structure changed relative to the tree
    # this one was reparsed from; `nil` for a fresh parse.
    getter changed_ranges : Array(TextRange)?
    @raw : LibTreeSitter::TSTree*

    protected def initialize(@raw, @text, @line_index, @changed_ranges = nil)
    end

    def finalize
      LibTreeSitter.ts_tree_delete(@raw)
    end

    def to_unsafe : LibTreeSitter::TSTree*
      @raw
    end

    def root : Node
      Node.new(LibTreeSitter.ts_tree_root_node(@raw), self)
    end

    def has_error? : Bool
      root.has_error?
    end

    # Cheap reference-counted copy, for use on another thread.
    def copy : Tree
      Tree.new(LibTreeSitter.ts_tree_copy(@raw), @text, @line_index)
    end

    # Tree-sitter requires the *edited* old tree here, so this is only called
    # from `Parser#reparse`.
    protected def compute_changed_ranges(edited_old : Tree) : Nil
      ptr = LibTreeSitter.ts_tree_get_changed_ranges(edited_old, @raw, out count)
      @changed_ranges = Array(TextRange).new(count) { |i| TextRange.new(ptr[i].start_byte, ptr[i].end_byte) }
    ensure
      Syntax.free_native(ptr.as(Void*)) if ptr
    end
  end

  # Wraps a `TSParser`. Not thread-safe; use one parser per thread.
  class Parser
    @raw : LibTreeSitter::TSParser*

    def initialize
      @raw = LibTreeSitter.ts_parser_new
      unless LibTreeSitter.ts_parser_set_language(@raw, Grammar.language)
        raise "incompatible tree-sitter-crystal ABI #{Grammar.abi_version}"
      end
    end

    def finalize
      LibTreeSitter.ts_parser_delete(@raw)
    end

    def parse(text : String) : Tree
      build(text, LineIndex.new(text), nil)
    end

    # Applies *edits* (each in offsets of the text produced by the previous
    # edit, like LSP incremental changes) and reparses incrementally.
    def reparse(old : Tree, edits : Enumerable(TextEdit)) : Tree
      raw = LibTreeSitter.ts_tree_copy(old)
      text = old.text
      index = old.line_index
      edits.each do |edit|
        new_text = edit.apply(text)
        new_index = LineIndex.new(new_text)
        new_end = edit.range.start + edit.new_text.bytesize
        input = LibTreeSitter::TSInputEdit.new(
          start_byte: edit.range.start,
          old_end_byte: edit.range.end,
          new_end_byte: new_end,
          start_point: ts_point(index.point(edit.range.start)),
          old_end_point: ts_point(index.point(edit.range.end)),
          new_end_point: ts_point(new_index.point(new_end)),
        )
        LibTreeSitter.ts_tree_edit(raw, pointerof(input))
        text, index = new_text, new_index
      end
      edited = Tree.new(raw, text, index)
      tree = build(text, index, edited)
      tree.compute_changed_ranges(edited)
      tree
    end

    private def build(text : String, index : LineIndex, old : Tree?) : Tree
      old_raw = old ? old.to_unsafe : Pointer(LibTreeSitter::TSTree).null
      raw = LibTreeSitter.ts_parser_parse_string(@raw, old_raw, text, text.bytesize)
      raise "tree-sitter parse failed" if raw.null?
      Tree.new(raw, text, index)
    end

    private def ts_point(p : LineCol) : LibTreeSitter::TSPoint
      LibTreeSitter::TSPoint.new(row: p.line, column: p.column)
    end
  end
end
