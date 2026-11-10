module ClearLS::IDE
  # Where a cursor is inside an annotation (`@[Name(args)]`), from the
  # text: half-typed annotations parse as `ERROR` (`@[` alone, or
  # `@[JSON::` swallowing the next `def`), so the CST can't say.
  module AnnotationContext
    # In the name: `@[`, `@[Li`, `@[JSON::F`. *qualifier*: the path
    # before the last `::` (`JSON`; empty for none, `::` for a global
    # `@[::Li`); *prefix*: the segment being typed; *start*: its offset.
    record Name, qualifier : String, prefix : String, start : UInt32

    # In the argument list, at an argument's start (after `(` or `,`):
    # `@[Link(`, `@[Link("m", pk`. *name*: the annotation path;
    # *prefix*/*start*: the word being typed; *written*: named
    # arguments already given; *positional*: positional ones before
    # the cursor.
    record Args, name : String, prefix : String, start : UInt32, written : Array(String), positional : Int32

    # How far back an annotation may start.
    MAX_SCAN = 4096

    NAME_RE = /\A\s*((?:::)?(?:[A-Z]\w*::)*)([A-Z]\w*)?\z/

    def self.at(text : String, offset : UInt32) : Name | Args | Nil
      from = offset > MAX_SCAN ? offset - MAX_SCAN : 0_u32
      window = text.byte_slice(from, offset - from)
      at = window.rindex("@[") || return nil
      start = from + at
      scan(text, start + 2, offset)
    end

    # Lexes `@[` ... up to *offset*: strings, chars and nested brackets.
    # Nil when the annotation closes before the cursor, or the cursor is
    # inside a string, char or nested bracket other than the argument
    # list.
    private def self.scan(text : String, body : UInt32, offset : UInt32) : Name | Args | Nil
      stack = [] of Char # closers expected
      i = body
      args_open = nil.as(UInt32?)
      arg_start = nil.as(UInt32?)
      written = [] of String
      positional = 0
      while i < offset
        c = text.byte_at(i).chr
        case c
        when '"', '\''
          close = skip_quoted(text, i, offset, c) || return nil
          i = close
          next
        when '#'
          # A comment runs to the line end (a `#` inside a string is
          # skipped with the string).
          nl = text.byte_index('\n', i.to_i32) || return nil
          return nil if nl >= offset
          i = nl.to_u32
        when '(', '[', '{'
          if stack.empty? && c == '('
            args_open = i
            arg_start = i + 1
          end
          stack << {'(' => ')', '[' => ']', '{' => '}'}[c]
        when ')', ']', '}'
          if stack.empty?
            return nil # `]` of the annotation itself: closed
          end
          return nil unless stack.pop == c
          return nil if stack.empty? && c == ')' # args closed, `]` pending
        when ','
          if stack.size == 1 && args_open
            note_arg(text, arg_start.not_nil!, i, written) { positional += 1 }
            arg_start = i + 1
          end
        end
        i += 1
      end
      if stack.empty?
        typed = text.byte_slice(body, offset - body)
        m = typed.match(NAME_RE) || return nil
        prefix = m[2]? || ""
        qualifier = m[1].rchop("::")
        qualifier = "::" if qualifier.empty? && m[1] == "::"
        return Name.new(qualifier, prefix, offset - prefix.bytesize)
      end
      return nil unless stack.size == 1 && (open = args_open) && (a = arg_start)
      current = text.byte_slice(a, offset - a)
      m = current.match(/\A\s*([a-z_]\w*)?\z/) || return nil
      prefix = m[1]? || ""
      name = text.byte_slice(body, open - body).strip
      Args.new(name, prefix, offset - prefix.bytesize, written, positional)
    end

    # Records the argument `[from, to)`: `name: value` adds *name* to
    # *written*, anything else counts as positional.
    private def self.note_arg(text : String, from : UInt32, to : UInt32, written : Array(String), &) : Nil
      arg = text.byte_slice(from, to - from)
      if m = arg.match(/\A\s*([a-z_]\w*)\s*:(?!:)/)
        written << m[1]
      elsif !arg.strip.empty?
        yield
      end
    end

    # Offset after the closing quote of the string or char at *i*; nil
    # when it doesn't close before *offset*.
    private def self.skip_quoted(text : String, i : UInt32, offset : UInt32, quote : Char) : UInt32?
      j = i + 1
      while j < offset
        c = text.byte_at(j).chr
        if c == '\\'
          j += 2
          next
        end
        return j + 1 if c == quote
        j += 1
      end
      nil
    end
  end
end
