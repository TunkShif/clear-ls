require "../hir"
require "../semantics/def_map"
require "./locals"

module ClearLS::IDE
  # Semantic token types and modifiers. Order defines the LSP legend.
  enum TokenType
    Namespace
    Type
    Class
    Struct
    Enum
    EnumMember
    TypeParameter
    Parameter
    Variable
    Property # instance / class variables
    Function # top-level def, lib fun
    Method
    Macro
  end

  @[Flags]
  enum TokenModifier
    Declaration
    Readonly # constants
    Static   # class methods, class vars
    Abstract
    DefaultLibrary # stdlib
  end

  record Token, range : TextRange, type : TokenType, modifiers : TokenModifier

  # Tokens Tree-sitter highlighting cannot classify by itself: local vs
  # parameter, references to types, declarations, ivars.
  class SemanticTokens
    # *stdlib_file* tells whether a file belongs to the standard library,
    # for the `defaultLibrary` modifier.
    def initialize(@state : FileState, @bodies : Bodies, @def_map : Semantics::DefMap?,
                   @stdlib_file : Proc(FileId, Bool) = ->(_f : FileId) { false })
    end

    def tokens(range : TextRange? = nil) : Array(Token)
      result = [] of Token
      tree = @state.tree
      covered = Set(UInt32).new
      emit = ->(r : TextRange, t : TokenType, m : TokenModifier) do
        return if range && !(r.end > range.start && r.start < range.end)
        result << Token.new(r, t, m) if covered.add?(r.start)
      end

      # Locals and params from body HIR.
      each_body(tree) do |body|
        body.bindings.each do |b|
          type = b.kind.param? || b.kind.block_param? || b.kind.block_arg? ? TokenType::Parameter : TokenType::Variable
          b.references.each do |r|
            emit.call(r.range, type, r.kind.decl? ? TokenModifier::Declaration : TokenModifier::None)
          end
        end
      end

      tree.root.walk do |node|
        if range && (node.end_byte <= range.start || node.start_byte >= range.end)
          next false
        end
        case node.kind
        when .instance_var?
          emit.call(node.range, TokenType::Property, TokenModifier::None)
        when .class_var?
          emit.call(node.range, TokenType::Property, TokenModifier::Static)
        when .method_def?, .abstract_method_def?, .macro_def?, .fun_def?
          if name = node.field(Syntax::Field::Name)
            type = node.kind.macro_def? ? TokenType::Macro : (node.kind.fun_def? || top_level?(node) ? TokenType::Function : TokenType::Method)
            mods = TokenModifier::Declaration
            mods |= TokenModifier::Static if node.fields(Syntax::Field::ClassNode).any?(&.named?)
            mods |= TokenModifier::Abstract if node.kind.abstract_method_def?
            emit.call(name.range, type, mods)
          end
        when .constant?
          constant_tokens(node, emit)
          next false
        when .generic_type?
          # `class Foo(T)`: T is a type parameter.
          node.field(Syntax::Field::Params).try &.named_children.each do |p|
            target = p.kind.splat? ? p.named_child(0) : p
            emit.call(target.range, TokenType::TypeParameter, TokenModifier::Declaration) if target
          end
        when .comment?, .string_node?, .heredoc_body?
          next node.kind.string_node? # interpolations may contain code
        end
        true
      end
      result.sort_by!(&.range.start)
    end

    # Splits `Foo::Bar::Baz` into segments and classifies each resolved
    # prefix (namespace / class / struct / enum / constant).
    private def constant_tokens(node : Syntax::Node, emit) : Nil
      text = node.text
      start = node.start_byte
      decl = declaration_name?(node)
      ns = @def_map.try(&.namespace_at(@state.id, node.start_byte))
      offset = 0
      while offset < text.bytesize
        offset += 2 if text.byte_slice(offset, 2) == "::"
        seg_end = text.byte_index("::", offset) || text.bytesize
        break if seg_end <= offset
        prefix = text.byte_slice(0, seg_end)
        r = TextRange.new(start + offset, start + seg_end)
        last = seg_end == text.bytesize
        type, mods = classify(prefix, ns)
        mods |= TokenModifier::Declaration if decl && last
        emit.call(r, type, mods)
        offset = seg_end
      end
    end

    private def classify(path : String, ns : Semantics::TypeId?) : {TokenType, TokenModifier}
      map = @def_map
      unknown = path.split("::").last.matches?(/\A[A-Z][A-Z0-9_]+\z/) ? {TokenType::Variable, TokenModifier::Readonly} : {TokenType::Type, TokenModifier::None}
      return unknown unless map && ns
      id = map.lookup_path(path, ns) || return unknown
      info = map[id]
      mods = TokenModifier::None
      if !info.sites.empty? && info.sites.all? { |s| stdlib_file?(s.file) }
        mods |= TokenModifier::DefaultLibrary
      end
      type = case info.kind
             when .module?, .lib?, .program? then TokenType::Namespace
             when .class?, .annotation?      then TokenType::Class
             when .struct?, .c_struct?, .c_union? then TokenType::Struct
             when .enum?                     then TokenType::Enum
             else                                 TokenType::Type
             end
      {type, mods}
    end

    @stdlib_cache = {} of FileId => Bool

    private def stdlib_file?(file : FileId) : Bool
      @stdlib_cache.put_if_absent(file) { @stdlib_file.call(file) }
    end

    private def declaration_name?(node : Syntax::Node) : Bool
      parent = node.parent || return false
      kind = parent.kind
      if kind.generic_type?
        return parent.named_child(0) == node && parent.parent.try { |pp| declaration_kind?(pp.kind) } || false
      end
      return parent.field(Syntax::Field::Name) == node if declaration_kind?(kind)
      return parent.field(Syntax::Field::Lhs) == node if kind.const_assign?
      parent.parent.try(&.kind.enum_def?) && kind.expressions? || false
    end

    private def declaration_kind?(kind : Syntax::Kind) : Bool
      kind.class_def? || kind.struct_def? || kind.module_def? || kind.enum_def? || kind.lib_def? ||
        kind.alias_node? || kind.annotation_def? || kind.c_struct_def? || kind.union_def? || kind.type_def?
    end

    private def top_level?(node : Syntax::Node) : Bool
      p = node.parent
      while pp = p
        return false if declaration_kind?(pp.kind)
        p = pp.parent
      end
      true
    end

    # Every def body plus the file body.
    private def each_body(tree : Syntax::Tree, & : HIR::Body ->) : Nil
      @bodies.at(0).try { |b| yield b }
      tree.root.walk do |n|
        if n.kind.method_def?
          @bodies.at(n.start_byte + 1).try { |b| yield b }
        end
        true
      end
    end

    # LSP relative encoding: [deltaLine, deltaStart, length, type, modifiers]*.
    # Multi-line tokens are dropped (LSP clients disagree on them).
    def self.encode(tokens : Array(Token), index : LineIndex, encoding : PositionEncoding) : Array(UInt32)
      data = [] of UInt32
      prev_line = 0_u32
      prev_col = 0_u32
      tokens.each do |t|
        a = index.position(t.range.start, encoding)
        b = index.position(t.range.end, encoding)
        next unless a.line == b.line && b.column > a.column
        delta_line = a.line - prev_line
        delta_col = delta_line == 0 ? a.column - prev_col : a.column
        data << delta_line << delta_col << (b.column - a.column) << t.type.value.to_u32 << t.modifiers.value.to_u32
        prev_line, prev_col = a.line, a.column
      end
      data
    end
  end
end
