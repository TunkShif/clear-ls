require "tree_sitter"
require "./kinds"

# Statically linked Crystal grammar. The Makefile's local pkg-config files
# resolve to the vendored archives.
@[Link(pkg_config: "tree-sitter-crystal")]
lib LibTreeSitterCrystal
  fun tree_sitter_crystal : LibTreeSitter::TSLanguage*
end

# Declarations missing from (or outdated in) the pinned binding.
lib LibTreeSitter
  fun ts_language_abi_version(TSLanguage*) : LibC::UInt32T
end

module ClearLS::Syntax
  # The Crystal language plus lookup tables between grammar IDs and the
  # generated `Kind`/`Field` enums.
  module Grammar
    @@language : LibTreeSitter::TSLanguage* = LibTreeSitterCrystal.tree_sitter_crystal
    @@kinds = [] of Kind
    @@fields = [] of Field
    @@field_ids = [] of UInt16

    def self.language : LibTreeSitter::TSLanguage*
      @@language
    end

    def self.abi_version : UInt32
      LibTreeSitter.ts_language_abi_version(@@language)
    end

    # Kind for a grammar symbol ID.
    def self.kind(symbol : UInt16) : Kind
      @@kinds[symbol]? || Kind::Unknown
    end

    # Field enum for a grammar field ID.
    def self.field(id : UInt16) : Field
      @@fields[id]? || Field::None
    end

    # Grammar field ID for a `Field`.
    def self.field_id(field : Field) : UInt16
      @@field_ids[field.value]
    end

    def self.symbol_name(symbol : UInt16) : String
      String.new(LibTreeSitter.ts_language_symbol_name(@@language, symbol.unsafe_as(LibTreeSitter::TSSymbol)))
    end

    protected def self.build_tables : Nil
      by_name = {} of String => Kind
      Kind.each { |k| by_name[KIND_NAMES[k.value]] = k unless KIND_NAMES[k.value].empty? }

      count = LibTreeSitter.ts_language_symbol_count(@@language)
      @@kinds = Array(Kind).new(count) do |i|
        sym = i.to_u16.unsafe_as(LibTreeSitter::TSSymbol)
        type = LibTreeSitter.ts_language_symbol_type(@@language, sym)
        name = String.new(LibTreeSitter.ts_language_symbol_name(@@language, sym))
        if name == "ERROR"
          Kind::Error
        elsif type.regular?
          by_name[name]? || Kind::Unknown
        else
          Kind::Anonymous
        end
      end
      # ts_node_symbol returns 0xFFFF (ts_builtin_sym_error) for ERROR nodes.
      @@kinds.concat(Array.new(0x10000 - count, Kind::Unknown))
      @@kinds[0xFFFF] = Kind::Error

      fcount = LibTreeSitter.ts_language_field_count(@@language)
      @@field_ids = Array(UInt16).new(Field.values.size, 0_u16)
      @@fields = Array(Field).new(fcount + 1) do |i|
        next Field::None if i == 0
        name = String.new(LibTreeSitter.ts_language_field_name_for_id(@@language, i.to_u16.unsafe_as(LibTreeSitter::TSFieldId)))
        if field = Field.values.find { |f| FIELD_NAMES[f.value] == name }
          @@field_ids[field.value] = i.to_u16
          field
        else
          Field::None
        end
      end
    end

    build_tables
  end
end
