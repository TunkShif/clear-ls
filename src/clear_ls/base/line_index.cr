require "./text_range"

module ClearLS
  # Units used to count columns in LSP positions.
  enum PositionEncoding
    UTF8
    UTF16
    UTF32

    def self.from_lsp?(name : String) : self?
      case name
      when "utf-8"  then UTF8
      when "utf-16" then UTF16
      when "utf-32" then UTF32
      end
    end

    def to_lsp : String
      case self
      in .utf8?  then "utf-8"
      in .utf16? then "utf-16"
      in .utf32? then "utf-32"
      end
    end
  end

  # Zero-based line and column. The column unit depends on context:
  # bytes for Tree-sitter points, `PositionEncoding` units for LSP.
  record LineCol, line : UInt32, column : UInt32 do
    def to_s(io : IO) : Nil
      io << line << ':' << column
    end
  end

  # Maps byte offsets to line/column pairs for one immutable text.
  #
  # Line breaks are `\n`; a `\r` before it belongs to the line content, which
  # matches both Tree-sitter rows and LSP lines. Columns computed with a
  # non-byte encoding decode only the affected line.
  class LineIndex
    getter text : String
    # Byte offset where each line starts. Always non-empty; `[0] == 0`.
    getter line_starts : Array(UInt32)

    def initialize(@text : String)
      @line_starts = [0_u32]
      @text.to_slice.each_with_index do |byte, i|
        @line_starts << (i + 1).to_u32 if byte == '\n'.ord
      end
    end

    def line_count : Int32
      @line_starts.size
    end

    def text_size : UInt32
      @text.bytesize.to_u32
    end

    # Line containing *offset*. Offsets past the end clamp to the last line.
    def line_of(offset : UInt32) : UInt32
      offset = Math.min(offset, text_size)
      idx = @line_starts.bsearch_index { |start| start > offset } || @line_starts.size
      (idx - 1).to_u32
    end

    # Byte range of *line* excluding its `\n` terminator.
    def line_range(line : UInt32) : TextRange
      start = @line_starts[line]
      stop = if line + 1 < @line_starts.size
               @line_starts[line + 1] - 1
             else
               text_size
             end
      TextRange.new(start, stop)
    end

    # Byte offset to a line and byte column (a Tree-sitter point).
    def point(offset : UInt32) : LineCol
      offset = Math.min(offset, text_size)
      line = line_of(offset)
      LineCol.new(line, offset - @line_starts[line])
    end

    # Byte offset to a line and *encoding* column (an LSP position).
    def position(offset : UInt32, encoding : PositionEncoding) : LineCol
      offset = snap_to_char(Math.min(offset, text_size))
      line = line_of(offset)
      start = @line_starts[line]
      return LineCol.new(line, offset - start) if encoding.utf8?

      LineCol.new(line, count_units(start, offset, encoding))
    end

    # LSP position to a byte offset.
    #
    # Lines past the end clamp to the end of text. Columns past the end of a
    # line clamp to the line end (LSP says to default to the line length).
    # Columns inside a multi-unit character snap to that character's start.
    def offset(pos : LineCol, encoding : PositionEncoding) : UInt32
      return text_size if pos.line >= @line_starts.size

      range = line_range(pos.line)
      if encoding.utf8?
        return snap_to_char(Math.min(range.start + pos.column, range.end))
      end

      remaining = pos.column
      offset = range.start
      while offset < range.end && remaining > 0
        width, units = char_at(offset, encoding)
        break if units > remaining
        remaining -= units
        offset += width
      end
      offset
    end

    # Rounds an offset that falls inside a UTF-8 sequence down to its start.
    private def snap_to_char(offset : UInt32) : UInt32
      bytes = @text.to_slice
      while offset > 0 && offset < bytes.size && (bytes[offset] & 0xC0) == 0x80
        offset -= 1
      end
      offset
    end

    private def count_units(from : UInt32, to : UInt32, encoding : PositionEncoding) : UInt32
      units = 0_u32
      offset = from
      while offset < to
        width, n = char_at(offset, encoding)
        units += n
        offset += width
      end
      units
    end

    # Byte width and *encoding* unit count of the character at *offset*.
    # Invalid bytes count as one byte and one unit.
    private def char_at(offset : UInt32, encoding : PositionEncoding) : {UInt32, UInt32}
      lead = @text.to_slice[offset]
      width = if lead < 0x80
                1_u32
              elsif lead >= 0xF0
                4_u32
              elsif lead >= 0xE0
                3_u32
              elsif lead >= 0xC0
                2_u32
              else
                1_u32
              end
      width = Math.min(width, text_size - offset)
      units = encoding.utf16? && width == 4 ? 2_u32 : 1_u32
      {width, units}
    end
  end
end
