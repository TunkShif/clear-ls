require "../semantics/def_map"

module ClearLS::Types
  # Interned type handle. Equal types share one id within a `TypeTable`.
  record TyId, value : Int32

  enum TyKind
    Unknown   # nothing known (open)
    Named     # a DefMap type, optionally with generic args
    Union
    Tuple
    NamedTuple
    Proc
    Metaclass # `Foo.class`, the type of the constant `Foo`
    TypeParam # unresolved generic parameter `T` inside its owner
    NoReturn
  end

  # Structural type. Generic args, union members, tuple elements, and proc
  # params+return all live in `args`; named tuple keys in `names`.
  struct Ty
    getter kind : TyKind
    getter def_id : Semantics::TypeId?
    getter args : Array(TyId)
    getter names : Array(String)
    # TypeParam name.
    getter param : String?

    def initialize(@kind, @def_id = nil, @args = [] of TyId, @names = [] of String, @param = nil)
    end

    def key : {TyKind, Int32, Array(Int32), Array(String), String?}
      {kind, def_id.try(&.value) || -1, args.map(&.value), names, param}
    end
  end

  # Interns types and formats them. One table per DefMap generation.
  class TypeTable
    getter def_map : Semantics::DefMap
    @types = [] of Ty
    @ids = {} of {TyKind, Int32, Array(Int32), Array(String), String?} => TyId

    getter unknown : TyId
    getter no_return : TyId

    def initialize(@def_map)
      @unknown = intern(Ty.new(TyKind::Unknown))
      @no_return = intern(Ty.new(TyKind::NoReturn))
    end

    def [](id : TyId) : Ty
      @types[id.value]
    end

    def intern(ty : Ty) : TyId
      @ids[ty.key] ||= begin
        @types << ty
        TyId.new(@types.size - 1)
      end
    end

    def named(def_id : Semantics::TypeId, args = [] of TyId) : TyId
      intern(Ty.new(TyKind::Named, def_id, args))
    end

    # Looks a stdlib/top-level type up by name (`String`, `Int32`, `Nil`).
    def named?(name : String, args = [] of TyId) : TyId?
      @def_map.lookup_path("::#{name}").try { |d| named(d, args) }
    end

    def named!(name : String, args = [] of TyId) : TyId
      named?(name, args) || @unknown
    end

    def metaclass(instance : TyId) : TyId
      intern(Ty.new(TyKind::Metaclass, args: [instance]))
    end

    def type_param(name : String) : TyId
      intern(Ty.new(TyKind::TypeParam, param: name))
    end

    def tuple(elems : Array(TyId)) : TyId
      intern(Ty.new(TyKind::Tuple, args: elems))
    end

    def named_tuple(names : Array(String), elems : Array(TyId)) : TyId
      intern(Ty.new(TyKind::NamedTuple, args: elems, names: names))
    end

    def proc(params : Array(TyId), ret : TyId) : TyId
      intern(Ty.new(TyKind::Proc, args: params + [ret]))
    end

    # Flattened, deduplicated, ordered union. Unknown absorbs everything
    # (an unknown member means we cannot list the alternatives), NoReturn
    # disappears.
    def union(members : Enumerable(TyId)) : TyId
      flat = [] of TyId
      members.each do |m|
        t = self[m]
        case t.kind
        when .union?     then t.args.each { |a| flat << a unless flat.includes?(a) }
        when .no_return? then next
        when .unknown?   then return @unknown
        else                  flat << m unless flat.includes?(m)
        end
      end
      return @no_return if flat.empty?
      return flat.first if flat.size == 1
      flat.sort_by! { |id| {nil_type?(id) ? 1 : 0, id.value} }
      intern(Ty.new(TyKind::Union, args: flat))
    end

    def nilable(id : TyId) : TyId
      union([id, named!("Nil")])
    end

    def unknown?(id : TyId) : Bool
      self[id].kind.unknown?
    end

    def nil_type?(id : TyId) : Bool
      t = self[id]
      t.kind.named? && @def_map[t.def_id.not_nil!].full_name == "Nil"
    end

    # Union members, or the type itself.
    def members(id : TyId) : Array(TyId)
      t = self[id]
      t.kind.union? ? t.args : [id]
    end

    # Removes `Nil` from a union (for `not_nil!`, `x.try`, `if x`).
    def without_nil(id : TyId) : TyId
      union(members(id).reject { |m| nil_type?(m) })
    end

    # Formats like the compiler: `Array(String)`, `Int32 | Nil` → `Int32?`.
    def to_s(id : TyId, io : IO) : Nil
      t = self[id]
      case t.kind
      in .unknown?    then io << '?'
      in .no_return?  then io << "NoReturn"
      in .type_param? then io << t.param
      in .named?
        io << @def_map[t.def_id.not_nil!].full_name
        unless t.args.empty?
          io << '('
          t.args.each_with_index { |a, i| io << ", " if i > 0; to_s(a, io) }
          io << ')'
        end
      in .union?
        non_nil = t.args.reject { |a| nil_type?(a) }
        if non_nil.size == 1 && t.args.size == 2
          paren = self[non_nil[0]].kind.proc?
          io << '(' if paren
          to_s(non_nil[0], io)
          io << ')' if paren
          io << '?'
        else
          t.args.each_with_index { |a, i| io << " | " if i > 0; to_s(a, io) }
        end
      in .tuple?
        io << '{'
        t.args.each_with_index { |a, i| io << ", " if i > 0; to_s(a, io) }
        io << '}'
      in .named_tuple?
        io << '{'
        t.args.each_with_index { |a, i| io << ", " if i > 0; io << t.names[i] << ": "; to_s(a, io) }
        io << '}'
      in .proc?
        params = t.args[0...-1]
        params.each_with_index { |a, i| io << ", " if i > 0; to_s(a, io) }
        io << ' ' unless params.empty?
        io << "-> "
        to_s(t.args.last, io)
      in .metaclass?
        to_s(t.args[0], io)
        io << ".class"
      end
    end

    def to_s(id : TyId) : String
      String.build { |io| to_s(id, io) }
    end
  end
end
