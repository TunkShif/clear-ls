module ClearLS
  # XXH64 with seed 0: a hash that is the same in every process, unlike
  # `Object#hash` (seeded randomly at start-up). Use it for anything that
  # is persisted or compared across processes: item fingerprints, word
  # sets, content digests in the cache.
  module StableHash
    P1 = 0x9E3779B185EBCA87_u64
    P2 = 0xC2B2AE3D27D4EB4F_u64
    P3 = 0x165667B19E3779F9_u64
    P4 = 0x85EBCA77C2B2AE63_u64
    P5 = 0x27D4EB2F165667C5_u64

    def self.hash(s : String) : UInt64
      hash(s.to_slice)
    end

    def self.hash(data : Bytes) : UInt64
      ptr = data.to_unsafe
      len = data.size
      i = 0
      if len >= 32
        v1 = 0_u64 &+ P1 &+ P2
        v2 = P2
        v3 = 0_u64
        v4 = 0_u64 &- P1
        while i + 32 <= len
          v1 = round(v1, read64(ptr + i))
          v2 = round(v2, read64(ptr + i + 8))
          v3 = round(v3, read64(ptr + i + 16))
          v4 = round(v4, read64(ptr + i + 24))
          i += 32
        end
        h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
        h = merge(h, v1)
        h = merge(h, v2)
        h = merge(h, v3)
        h = merge(h, v4)
      else
        h = P5
      end
      h &+= len.to_u64
      while i + 8 <= len
        h ^= round(0_u64, read64(ptr + i))
        h = rotl(h, 27) &* P1 &+ P4
        i += 8
      end
      if i + 4 <= len
        h ^= read32(ptr + i).to_u64 &* P1
        h = rotl(h, 23) &* P2 &+ P3
        i += 4
      end
      while i < len
        h ^= ptr[i].to_u64 &* P5
        h = rotl(h, 11) &* P1
        i += 1
      end
      h ^= h >> 33
      h &*= P2
      h ^= h >> 29
      h &*= P3
      h ^ (h >> 32)
    end

    @[AlwaysInline]
    private def self.round(acc : UInt64, input : UInt64) : UInt64
      rotl(acc &+ input &* P2, 31) &* P1
    end

    @[AlwaysInline]
    private def self.merge(h : UInt64, v : UInt64) : UInt64
      (h ^ round(0_u64, v)) &* P1 &+ P4
    end

    @[AlwaysInline]
    private def self.rotl(x : UInt64, r : Int32) : UInt64
      (x << r) | (x >> (64 - r))
    end

    # Little-endian loads (unaligned).
    @[AlwaysInline]
    private def self.read64(p : UInt8*) : UInt64
      v = uninitialized UInt64
      p.copy_to(pointerof(v).as(UInt8*), 8)
      {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::BigEndian %} v.byte_swap {% else %} v {% end %}
    end

    @[AlwaysInline]
    private def self.read32(p : UInt8*) : UInt32
      v = uninitialized UInt32
      p.copy_to(pointerof(v).as(UInt8*), 4)
      {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::BigEndian %} v.byte_swap {% else %} v {% end %}
    end
  end
end
