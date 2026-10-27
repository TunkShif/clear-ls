require "../base/text_range"
require "./cond"

module ClearLS::Items
  # What kind of declaration an `Item` is.
  enum ItemKind
    Module
    Class
    Struct
    Enum
    Lib
    Annotation
    Alias      # `alias A = T`, also `alias` inside `lib`
    TypeDef    # `type T = U` inside `lib`
    CStruct    # `struct` inside `lib`
    CUnion     # `union` inside `lib`
    Constant   # `A = 1`, also enum members
    Def        # `def`, also `abstract def`
    Macro      # `macro`
    Fun        # `fun` inside `lib`
    CVar       # `$x : T` inside `lib`
    CField     # field of a `lib` struct/union
    InstanceVar
    ClassVar

    def namespace? : Bool
      module? || class? || struct? || enum? || lib? || c_struct? || c_union? || annotation?
    end

    def type? : Bool
      namespace? || alias? || type_def?
    end
  end

  enum Visibility
    Public
    Protected
    Private
  end

  # How we learned about an item.
  enum Origin
    Source # written in source
    Macro  # synthesised from a known macro call (getter, record, ...)
    Compiler # reported by the compiler (hooks, `{% for %}`, inferred ivars)
    # `@x = value` inside a def (type_inference.md rules): `detail` is the
    # value text, or for `@x = param` the param's restriction (`: T`) or
    # default (`= v`) text; `signature` is nil. `doc` holds the enclosing
    # def's name.
    Assigned
  end

  # How a parameter binds arguments.
  enum ParamKind
    Positional
    Splat       # *args, or bare `*` (named-only marker)
    DoubleSplat # **opts
    Block       # &block
  end

  # One parameter as written. Defaults are a property, not extra overloads.
  record Param,
    kind : ParamKind,
    name : String?,          # internal name; `nil` for bare `*` / `&`
    external_name : String?, # differs from name when written `ext int`
    restriction : String?,   # type restriction text as written
    default : String?,       # default value text as written
    range : TextRange do
    # Name used for named arguments at call sites.
    def call_name : String?
      external_name || name
    end

    def to_s(io : IO) : Nil
      case kind
      in .splat?        then io << '*'
      in .double_splat? then io << "**"
      in .block?        then io << '&'
      in .positional?
      end
      if (ext = external_name) && ext != name
        io << ext << ' '
      end
      if name
        io << name
        io << " : " << restriction if restriction
      elsif restriction
        io << restriction # unnamed `fun` parameter
      end
      io << " = " << default if default
    end
  end

  # Signature data for `def`, `macro`, and `fun` items.
  record Signature,
    params : Array(Param),
    return_type : String?,
    free_vars : Array(String), # `forall T, U`
    receiver : String?,        # `self` / `Foo` in `def self.foo` / `def Foo.foo`
    is_abstract : Bool,
    variadic : Bool,           # `fun f(...)`
    real_name : String? do     # `fun foo = c_foo`
    def to_s(io : IO) : Nil
      io << '('
      params.join(io, ", ") { |p, o| p.to_s(o) }
      io << ", ..." if variadic
      io << ')'
      io << " : " << return_type if return_type
      io << " forall " << free_vars.join(", ") unless free_vars.empty?
    end
  end

  # Header data for namespace items.
  record TypeHeader,
    # Path as written, without the `::` prefix: `Outer::Inner` → ["Outer", "Inner"].
    path : Array(String),
    global : Bool,          # written as `::Foo`
    type_params : Array(String),
    splat_index : Int32?,   # index of `*T` in type_params
    superclass : String?,   # text as written
    is_abstract : Bool,
    base_type : String?     # enum base type (`enum E : UInt8`)

  # One declaration in one file.
  #
  # Items form a tree mirroring lexical nesting. Identity is the item's index
  # within its file's `ItemTree`; cross-file identity is built in `DefMap`.
  class Item
    getter kind : ItemKind
    # Simple name: `Inner` for `module Outer::Inner`, `foo` for `def self.foo`.
    getter name : String
    # Whole declaration range, and the range to highlight / jump to.
    getter range : TextRange
    getter name_range : TextRange
    getter visibility : Visibility
    getter origin : Origin
    getter doc : String?
    getter annotations : Array(String)
    getter conditions : Array(Cond)
    getter header : TypeHeader?
    getter signature : Signature?
    # For constants, aliases, typedefs, ivars, fields: value or type text.
    getter detail : String?
    getter children = [] of Item
    # `include`/`extend` directives directly in this namespace, as written.
    getter includes = [] of String
    getter extends = [] of String

    def initialize(@kind, @name, @range, @name_range, *, @visibility = Visibility::Public,
                   @origin = Origin::Source, @doc = nil, @annotations = [] of String,
                   @conditions = [] of Cond, @header = nil, @signature = nil, @detail = nil)
    end

    # Pre-order traversal of all nested items (iterative: yielding blocks
    # cannot recurse in Crystal).
    def each_descendant(& : Item ->) : Nil
      stack = @children.reverse
      while item = stack.pop?
        yield item
        item.children.reverse_each { |c| stack << c }
      end
    end

    # Takes the positions of *other*, a re-lowering of this item after an
    # edit with an equal fingerprint (same declarations, moved). Items are
    # shared with the DefMap, so updating them in place keeps its sites
    # current without a rebuild.
    def move_to(other : Item) : Nil
      @range = other.range
      @name_range = other.name_range
      if (s = @signature) && (o = other.signature)
        @signature = s.copy_with(params: s.params.map_with_index { |p, i| o.params[i]?.try { |op| p.copy_with(range: op.range) } || p })
      end
      @children.each_with_index { |c, i| other.children[i]?.try { |oc| c.move_to(oc) } }
    end

    # Stable digest of everything except source positions, used to detect
    # whether an edit changed declarations.
    def fingerprint(io : IO) : Nil
      io << kind << '\0' << name << '\0' << visibility << '\0' << origin << '\0'
      io << doc << '\0' << annotations.join(',') << '\0' << conditions.join(',') << '\0'
      if h = header
        io << h.path.join("::") << h.global << h.type_params.join(',') << h.splat_index
        io << h.superclass << h.is_abstract << h.base_type
      end
      signature.to_s(io)
      if s = signature
        io << s.receiver << s.is_abstract << s.real_name
      end
      io << '\0' << detail << '\0' << includes.join(',') << '\0' << extends.join(',') << '\0'
      io << '['
      children.each(&.fingerprint(io))
      io << ']'
    end
  end

  # A `require` statement.
  record Require, path : String, range : TextRange, conditions : Array(Cond)

  # All declarations of one file. Bodies of defs are not represented.
  class ItemTree
    getter items : Array(Item)
    getter requires : Array(Require)
    # True when declarations were recovered from parse errors.
    getter recovered : Bool

    def initialize(@items, @requires, @recovered)
    end

    def each_item(& : Item ->) : Nil
      stack = @items.reverse
      while item = stack.pop?
        yield item
        item.children.reverse_each { |c| stack << c }
      end
    end

    # Takes the positions of *other* (equal fingerprint): see
    # `Item#move_to`.
    def move_to(other : ItemTree) : Nil
      @items.each_with_index { |item, i| other.items[i]?.try { |o| item.move_to(o) } }
      @requires = other.requires
    end

    # Changes only when declarations change, not when def bodies or
    # whitespace do.
    def fingerprint : UInt64
      digest = String.build do |io|
        @items.each(&.fingerprint(io))
        @requires.each { |r| io << "require " << r.path << r.conditions.join(',') << '\n' }
      end
      digest.hash
    end
  end
end
