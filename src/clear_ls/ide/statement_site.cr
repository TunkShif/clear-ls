require "../syntax"

module ClearLS::IDE
  # Where a word being completed sits, for structural snippets (`class`,
  # `def`, `if ... end`): at the start of a statement, and in which scope.
  #
  # Works on a parse of the text with the word replaced by a placeholder
  # identifier (`Completion::PLACEHOLDER`), so `cla|` is a statement when
  # the placeholder is one: a direct child of a statement list
  # (`expressions`, `then`). Anything else (an argument, an assignment's
  # value, `x if |`, `return |`) is not. A parse error before the word
  # makes the scope unknown (error recovery reparents what follows: a
  # word in a `lib` body, where identifiers don't parse, lands at the top
  # level), so the answer is nil; errors after the word don't matter.
  # Text after the word on its line (other than a comment) also rules a
  # snippet out: it would end up inside the inserted body.
  module StatementSite
    # Scope of the statement, as the compiler sees it (checked with
    # Crystal 1.22): `def`/types are errors inside a def ("can't define
    # class inside def") and inside `if`/`while`/blocks at any level
    # ("can't declare def dynamically"); `begin` is transparent; an enum
    # body takes defs and macros but no types; a lib body takes neither.
    enum Scope
      TopLevel
      Type    # class, struct, module body
      Enum
      Def     # def, macro, fun body
      Dynamic # inside if/while/case/block outside a def
    end

    PLACEHOLDER = "__cl__"

    # Scope of a statement started by the word `[start, offset)` of
    # *text*, or nil when the word is not at a statement start.
    def self.at(text : String, start : UInt32, offset : UInt32) : Scope?
      return nil unless rest_blank?(text, offset)
      patched = Syntax::TextEdit.new(TextRange.new(start, offset), PLACEHOLDER).apply(text)
      tree = Syntax::Parser.new.parse(patched)
      result = scope(tree, start, text, start, offset, PLACEHOLDER)
      Syntax.keep_alive(tree)
      result
    end

    # *tree* is the patched parse; *at* the placeholder's byte offset in
    # it. *text* and *start*/*offset* are the original buffer and word.
    def self.scope(tree : Syntax::Tree, at : UInt32, text : String, start : UInt32, offset : UInt32, placeholder : String) : Scope?
      return nil unless rest_blank?(text, offset)
      leaf = tree.root.descendant(at, at + placeholder.bytesize) || return nil
      return nil unless leaf.kind.identifier? && leaf.text == placeholder
      parent = leaf.parent || return nil
      # Where an identifier is not a valid statement (an enum body), the
      # parser wraps just the word in an ERROR: the word's own error.
      if parent.kind.error? && parent.named_child_count == 1 && (up = parent.parent)
        own_error = parent
        parent = up
      end
      return nil if error_before?(tree.root, at, own_error)
      # A statement list that is a value (`x = (a; |)`) is still a
      # statement position; good enough.
      return nil unless parent.kind.expressions? || parent.kind.then?
      scope_of(leaf)
    end

    private def self.scope_of(node : Syntax::Node) : Scope
      dynamic = false
      n = node.parent
      while n
        case n.kind
        when .method_def?, .macro_def?, .fun_def?, .abstract_method_def?
          return Scope::Def
        when .class_def?, .struct_def?, .module_def?
          return dynamic ? Scope::Dynamic : Scope::Type
        when .enum_def?
          return dynamic ? Scope::Dynamic : Scope::Enum
        when .if?, .unless?, .while?, .until?, .case?, .block?, .elsif?, .else?, .when?, .in?, .then?
          # `else` of a `begin`/`rescue` is also control flow; `then` only
          # appears inside `if`/`unless`/`when`.
          dynamic = true
        end
        n = n.parent
      end
      dynamic ? Scope::Dynamic : Scope::TopLevel
    end

    # An ERROR node (or a missing token) starting before *at*.
    private def self.error_before?(root : Syntax::Node, at : UInt32, own : Syntax::Node?) : Bool
      return false unless root.has_error?
      found = false
      root.walk do |n|
        next false if found || n.start_byte >= at
        next true unless n.has_error?
        next false if own && n.range == own.range
        if n.error? || n.missing?
          found = true
          next false
        end
        true
      end
      found
    end

    # Nothing but whitespace or a comment after *offset* on its line.
    def self.rest_blank?(text : String, offset : UInt32) : Bool
      i = offset
      while i < text.bytesize
        c = text.byte_at(i)
        return true if c == '\n'.ord || c == '#'.ord
        return false unless c == ' '.ord || c == '\t'.ord || c == '\r'.ord
        i += 1
      end
      true
    end
  end
end
