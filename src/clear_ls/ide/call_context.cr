module ClearLS::IDE
  # The call a cursor is inside of, found textually: the nearest unclosed
  # `(` before the cursor that follows a method name, the argument index,
  # and the named argument being written. Works on unfinished code
  # (`io.gets(1, `) where the CST is unreliable.
  #
  # The scan skips string, char, and symbol-ish literals and balanced
  # brackets; comments end at newlines. It does not understand heredocs or
  # `%()` literals (rare inside argument lists).
  struct CallContext
    getter open_paren : UInt32  # byte offset of `(`
    getter name_start : UInt32  # method name start
    getter arg_index : Int32    # positional index of the active argument
    getter named : String?      # `name:` of the active argument, if any
    getter commas : Int32       # commas before the cursor at depth 0
    # Names already given as `name:` before the active argument.
    getter given_names : Array(String)

    def initialize(@open_paren, @name_start, @arg_index, @named, @commas, @given_names)
    end

    MAX_SCAN = 4000

    def self.find(text : String, offset : UInt32) : CallContext?
      bytes = text.to_slice
      limit = offset > MAX_SCAN ? offset - MAX_SCAN : 0_u32
      # Forward-lex the window so strings and comments are known.
      start = line_start(bytes, limit)
      stack = [] of {Char, UInt32, Array(UInt32)} # bracket, offset, comma offsets
      i = start
      while i < offset
        c = bytes[i].unsafe_chr
        case c
        when '"', '`'
          i = skip_string(bytes, i, offset, c)
          next
        when '\''
          # Char literal: 'x', '\n', '\u{..}'.
          j = i + 1
          j += 1 if j < offset && bytes[j] == '\\'.ord
          j += 1
          while j < offset && bytes[j] != '\''.ord && j - i < 12
            j += 1
          end
          i = j + 1
          next
        when '#'
          while i < offset && bytes[i] != '\n'.ord
            i += 1
          end
          next
        when '(', '[', '{'
          stack << {c, i, [] of UInt32}
        when ')', ']', '}'
          stack.pop?
        when ','
          stack.last?.try { |top| top[2] << i }
        end
        i += 1
      end
      # Innermost `(` directly after a method name.
      stack.reverse_each do |(bracket, pos, commas)|
        next unless bracket == '('
        name_end = pos
        name_start = name_end
        while name_start > 0 && ident_byte?(bytes[name_start - 1])
          name_start -= 1
        end
        next if name_start == name_end
        first = bytes[name_start].unsafe_chr
        next unless first.lowercase? || first == '_'
        next if KEYWORDS.includes?(text.byte_slice(name_start, name_end - name_start))
        arg_start = commas.last? ? commas.last + 1 : pos + 1
        current = text.byte_slice(arg_start, offset - arg_start)
        named = current.match(/\A\s*([a-z_]\w*):(?!:)/).try(&.[1])
        given = [] of String
        prev = pos + 1
        commas.each do |cpos|
          seg = text.byte_slice(prev, cpos - prev)
          seg.match(/\A\s*([a-z_]\w*):(?!:)/).try { |m| given << m[1] }
          prev = cpos + 1
        end
        positional_before = commas.size - given.size
        return new(pos, name_start, positional_before, named, commas.size, given)
      end
      nil
    end

    KEYWORDS = %w(if unless while until case when return yield puts)

    private def self.ident_byte?(b : UInt8) : Bool
      c = b.unsafe_chr
      c.alphanumeric? || c == '_' || c == '?' || c == '!'
    end

    private def self.line_start(bytes : Bytes, at : UInt32) : UInt32
      i = at
      while i > 0 && bytes[i - 1] != '\n'.ord
        i -= 1
      end
      i
    end

    # Skips a string literal with `#{}` interpolation; returns the offset
    # after the closing quote (or *limit*).
    private def self.skip_string(bytes : Bytes, i : UInt32, limit : UInt32, quote : Char) : UInt32
      j = i + 1
      depth = 0
      while j < limit
        c = bytes[j].unsafe_chr
        if c == '\\'
          j += 2
          next
        end
        if depth == 0 && c == '#' && j + 1 < limit && bytes[j + 1] == '{'.ord
          depth = 1
          j += 2
          next
        end
        if depth > 0
          depth += 1 if c == '{'
          depth -= 1 if c == '}'
        elsif c == quote
          return j + 1
        end
        j += 1
      end
      limit
    end
  end
end
