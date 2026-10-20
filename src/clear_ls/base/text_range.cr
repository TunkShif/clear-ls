module ClearLS
  # Interned identity of a file in the VFS. Stable for the server lifetime.
  record FileId, value : UInt32 do
    def to_s(io : IO) : Nil
      io << "file#" << value
    end
  end

  # Half-open byte range `[start, end)` within one file's text.
  record TextRange, start : UInt32, end : UInt32 do
    def self.empty(offset : UInt32) : self
      new(offset, offset)
    end

    def size : UInt32
      self.end - start
    end

    def empty? : Bool
      start == self.end
    end

    def contains?(offset : UInt32) : Bool
      start <= offset < self.end
    end

    # Like `contains?` but also accepts the end offset (cursor positions).
    def touches?(offset : UInt32) : Bool
      start <= offset <= self.end
    end

    def covers?(other : TextRange) : Bool
      start <= other.start && other.end <= self.end
    end

    def to_s(io : IO) : Nil
      io << start << ".." << self.end
    end
  end
end
