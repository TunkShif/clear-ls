require "../items/item"
require "../items/cond"
require "../base/stable_hash"
require "../version"

module ClearLS::Cache
  # Bumped when the pack layout or any payload encoding changes (also bump
  # the patch version, docs/development.md#versions).
  SCHEMA = 1_u32

  MAGIC = "CLSC".to_slice

  # Read failure: wrong magic/schema/build, checksum mismatch, truncation.
  # Callers treat the pack as missing.
  class FormatError < Exception
  end

  # What a pack was written by. A pack whose key differs from the running
  # binary's is ignored (and rewritten).
  def self.build_key : String
    "#{VERSION}+#{BUILD_ID}"
  end

  # Set at compile time: the git commit of the source plus a digest of
  # uncommitted changes to `src/` (empty for a clean tree), and the
  # grammar commit. A work-in-progress build never reads packs of another.
  BUILD_ID = {{ `sh #{__DIR__}/../../../tools/build_id.sh`.chomp.stringify }}

  enum PackKind : UInt8
    Stdlib
    Shard
    Local
  end

  # One file in a pack: how to validate it and its payload.
  record FileMeta, path : String, size : Int64, mtime : Int64, hash : UInt64

  # Encodes item trees (and the local layer's extras) with a string
  # table: every string is written once and referenced by index.
  #
  # Layout (all integers little-endian):
  #
  #   magic "CLSC" | schema u32 | build key | kind u8 | pack key
  #   strings: count u32, then each as length u32 + bytes
  #   directory: count u32, then per file: path str, size i64, mtime i64,
  #              hash u64, payload offset u32, payload length u32
  #   payloads (offsets relative to the start of this section)
  #   checksum u64: StableHash of everything before it
  #
  # `str` in the header is length u32 + bytes; elsewhere strings are
  # table indices (u32, 0 = nil, n = table entry n - 1).
  class Writer
    @strings = [] of String
    @string_ids = {} of String => UInt32
    @payloads = IO::Memory.new
    @files = [] of {FileMeta, UInt32, UInt32}

    def initialize(@kind : PackKind, @key : String)
    end

    # Adds one file; the block writes its payload (`#tree`, `#str`, ...).
    def add(meta : FileMeta, & : Payload ->) : Nil
      start = @payloads.pos.to_u32
      yield Payload.new(@payloads, self)
      @files << {meta, start, @payloads.pos.to_u32 - start}
    end

    # Index of *s* in the string table (1-based; 0 is nil).
    def intern(s : String?) : UInt32
      return 0_u32 unless s
      @string_ids[s] ||= begin
        @strings << s
        @strings.size.to_u32
      end
    end

    def to_slice : Bytes
      io = IO::Memory.new
      io.write(MAGIC)
      u32(io, SCHEMA)
      raw(io, Cache.build_key)
      io.write_byte(@kind.value)
      raw(io, @key)
      u32(io, @strings.size.to_u32)
      @strings.each { |s| raw(io, s) }
      u32(io, @files.size.to_u32)
      @files.each do |(m, off, len)|
        raw(io, m.path)
        io.write_bytes(m.size, IO::ByteFormat::LittleEndian)
        io.write_bytes(m.mtime, IO::ByteFormat::LittleEndian)
        io.write_bytes(m.hash, IO::ByteFormat::LittleEndian)
        u32(io, off)
        u32(io, len)
      end
      io.write(@payloads.to_slice)
      io.write_bytes(StableHash.hash(io.to_slice), IO::ByteFormat::LittleEndian)
      io.to_slice
    end

    # Writes the pack atomically: a temp file renamed over *path*, so a
    # concurrent reader sees the old pack or the new one, never a part.
    def write(path : String) : Nil
      Dir.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{Random.rand(UInt32::MAX)}"
      File.write(tmp, to_slice)
      File.rename(tmp, path)
    rescue ex
      File.delete?(tmp) if tmp
      raise ex
    end

    private def u32(io : IO, v : UInt32) : Nil
      io.write_bytes(v, IO::ByteFormat::LittleEndian)
    end

    private def raw(io : IO, s : String) : Nil
      u32(io, s.bytesize.to_u32)
      io << s
    end
  end

  # Writes one payload. Strings go through the pack's string table.
  struct Payload
    def initialize(@io : IO::Memory, @writer : Writer)
    end

    def u8(v : UInt8) : Nil
      @io.write_byte(v)
    end

    def u32(v : UInt32) : Nil
      @io.write_bytes(v, IO::ByteFormat::LittleEndian)
    end

    def u64(v : UInt64) : Nil
      @io.write_bytes(v, IO::ByteFormat::LittleEndian)
    end

    def bool(v : Bool) : Nil
      u8(v ? 1_u8 : 0_u8)
    end

    def str(s : String?) : Nil
      u32(@writer.intern(s))
    end

    def strs(a : Array(String)) : Nil
      u32(a.size.to_u32)
      a.each { |s| str(s) }
    end

    def opt_i32(v : Int32?) : Nil
      u32(v ? (v + 1).to_u32 : 0_u32)
    end

    def range(r : TextRange) : Nil
      u32(r.start)
      u32(r.end)
    end

    def cond(c : Items::Cond) : Nil
      case c
      when Items::Cond::Flag
        u8(0); str(c.name)
      when Items::Cond::Not
        u8(1); cond(c.inner)
      when Items::Cond::And
        u8(2); cond(c.left); cond(c.right)
      when Items::Cond::Or
        u8(3); cond(c.left); cond(c.right)
      when Items::Cond::Unknown
        u8(4); str(c.text)
      else
        raise "unknown Cond #{c.class}"
      end
    end

    def conds(a : Array(Items::Cond)) : Nil
      u32(a.size.to_u32)
      a.each { |c| cond(c) }
    end

    def tree(t : Items::ItemTree) : Nil
      u32(t.items.size.to_u32)
      t.items.each { |i| item(i) }
      u32(t.requires.size.to_u32)
      t.requires.each { |r| str(r.path); range(r.range); conds(r.conditions) }
      bool(t.recovered)
      u32(t.mixins.size.to_u32)
      t.mixins.each { |m| str(m.path); bool(m.extend); range(m.range); conds(m.conditions) }
    end

    def item(i : Items::Item) : Nil
      u8(i.kind.value.to_u8)
      str(i.name)
      range(i.range)
      range(i.name_range)
      u8(i.visibility.value.to_u8)
      u8(i.origin.value.to_u8)
      str(i.doc)
      strs(i.annotations)
      conds(i.conditions)
      if h = i.header
        u8(1)
        strs(h.path); bool(h.global); strs(h.type_params); opt_i32(h.splat_index)
        str(h.superclass); bool(h.is_abstract); str(h.base_type)
      else
        u8(0)
      end
      if s = i.signature
        u8(1)
        u32(s.params.size.to_u32)
        s.params.each do |p|
          u8(p.kind.value.to_u8); str(p.name); str(p.external_name)
          str(p.restriction); str(p.default); range(p.range)
        end
        str(s.return_type); strs(s.free_vars); str(s.receiver)
        bool(s.is_abstract); bool(s.variadic); str(s.real_name)
      else
        u8(0)
      end
      str(i.detail)
      strs(i.includes)
      strs(i.extends)
      u32(i.children.size.to_u32)
      i.children.each { |c| item(c) }
    end
  end

  # A pack read into memory. Payloads are decoded on demand (`#tree`).
  class Pack
    getter kind : PackKind
    getter key : String
    getter build_key : String
    # Path → metadata and payload bounds.
    getter files = {} of String => {FileMeta, UInt32, UInt32}
    @strings = [] of String
    @payload_base = 0
    @bytes : Bytes

    def self.read(path : String) : Pack
      new(File.open(path, &.getb_to_end))
    rescue ex : File::Error | IO::Error
      raise FormatError.new("cannot read #{path}: #{ex.message}")
    end

    def initialize(@bytes : Bytes)
      @build_key = @key = ""
      @kind = PackKind::Local
      begin
        parse
      rescue ex : IO::EOFError | ArgumentError | IndexError | OverflowError
        raise FormatError.new("truncated or corrupt: #{ex.message}")
      end
    end

    private def parse : Nil
      raise FormatError.new("too short") if @bytes.size < MAGIC.size + 12
      body = @bytes[0, @bytes.size - 8]
      sum = IO::ByteFormat::LittleEndian.decode(UInt64, @bytes[@bytes.size - 8, 8])
      raise FormatError.new("checksum mismatch") unless StableHash.hash(body) == sum
      io = IO::Memory.new(body, writable: false)
      magic = Bytes.new(4)
      io.read_fully(magic)
      raise FormatError.new("bad magic") unless magic == MAGIC
      schema = u32(io)
      raise FormatError.new("schema #{schema}, expected #{SCHEMA}") unless schema == SCHEMA
      @build_key = raw(io)
      @kind = PackKind.new(io.read_byte || raise FormatError.new("truncated"))
      @key = raw(io)
      u32(io).times { @strings << raw(io) }
      u32(io).times do
        path = raw(io)
        size = io.read_bytes(Int64, IO::ByteFormat::LittleEndian)
        mtime = io.read_bytes(Int64, IO::ByteFormat::LittleEndian)
        hash = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        @files[path] = {FileMeta.new(path, size, mtime, hash), u32(io), u32(io)}
      end
      @payload_base = io.pos
    end

    def meta?(path : String) : FileMeta?
      @files[path]?.try(&.[0])
    end

    # A reader positioned at *path*'s payload.
    def payload(path : String) : Reader?
      _, off, len = @files[path]? || return nil
      Reader.new(@bytes[@payload_base + off, len], @strings)
    end

    private def u32(io : IO) : UInt32
      io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
    end

    private def raw(io : IO) : String
      io.read_string(u32(io))
    end
  end

  # Decodes one payload (the mirror of `Payload`).
  class Reader
    def initialize(bytes : Bytes, @strings : Array(String))
      @io = IO::Memory.new(bytes, writable: false)
    end

    def u8 : UInt8
      @io.read_byte || raise FormatError.new("truncated payload")
    end

    def u32 : UInt32
      @io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
    end

    def u64 : UInt64
      @io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
    end

    def bool : Bool
      u8 != 0
    end

    def str : String?
      i = u32
      return nil if i == 0
      @strings[i - 1]? || raise FormatError.new("bad string index #{i}")
    end

    def str! : String
      str || raise FormatError.new("unexpected nil string")
    end

    def strs : Array(String)
      Array(String).new(u32) { str! }
    end

    def opt_i32 : Int32?
      v = u32
      v == 0 ? nil : (v - 1).to_i32
    end

    def range : TextRange
      TextRange.new(u32, u32)
    end

    def cond : Items::Cond
      case tag = u8
      when 0 then Items::Cond::Flag.new(str!)
      when 1 then Items::Cond::Not.new(cond)
      when 2 then Items::Cond::And.new(cond, cond)
      when 3 then Items::Cond::Or.new(cond, cond)
      when 4 then Items::Cond::Unknown.new(str!)
      else        raise FormatError.new("bad cond tag #{tag}")
      end
    end

    def conds : Array(Items::Cond)
      Array(Items::Cond).new(u32) { cond }
    end

    def tree : Items::ItemTree
      items = Array(Items::Item).new(u32) { item }
      requires = Array(Items::Require).new(u32) { Items::Require.new(str!, range, conds) }
      recovered = bool
      mixins = Array(Items::TopLevelMixin).new(u32) { Items::TopLevelMixin.new(str!, bool, range, conds) }
      Items::ItemTree.new(items, requires, recovered, mixins)
    end

    def item : Items::Item
      kind = Items::ItemKind.from_value(u8)
      name = str!
      range = self.range
      name_range = self.range
      visibility = Items::Visibility.from_value(u8)
      origin = Items::Origin.from_value(u8)
      doc = str
      annotations = strs
      conditions = conds
      header = if bool
                 Items::TypeHeader.new(strs, bool, strs, opt_i32, str, bool, str)
               end
      signature = if bool
                    params = Array(Items::Param).new(u32) do
                      Items::Param.new(Items::ParamKind.from_value(u8), str, str, str, str, self.range)
                    end
                    Items::Signature.new(params, str, strs, str, bool, bool, str)
                  end
      detail = str
      item = Items::Item.new(kind, name, range, name_range, visibility: visibility, origin: origin,
        doc: doc, annotations: annotations, conditions: conditions, header: header,
        signature: signature, detail: detail)
      item.includes.concat(strs)
      item.extends.concat(strs)
      u32.times { item.children << self.item }
      item
    end
  end
end
