require "../items"

module ClearLS::Semantics
  # Identity of a merged type/namespace in a `DefMap`.
  record TypeId, value : Int32

  # A source location of a declaration.
  record Site, file : FileId, item : Items::Item

  # Kinds of merged semantic namespaces.
  enum TypeKind
    Program # top-level
    Module
    Class
    Struct
    Enum
    Lib
    Annotation
    CStruct
    CUnion
    Alias
    TypeDef

    def self.from(kind : Items::ItemKind) : self
      case kind
      when .module?     then Module
      when .class?      then Class
      when .struct?     then Struct
      when .enum?       then Enum
      when .lib?        then Lib
      when .annotation? then Annotation
      when .c_struct?   then CStruct
      when .c_union?    then CUnion
      when .alias?      then Alias
      when .type_def?   then TypeDef
      else                   raise ArgumentError.new("not a type item: #{kind}")
      end
    end
  end

  # One semantic type: every reopening of `class Foo` across files shares one
  # `TypeInfo` with several `sites`.
  class TypeInfo
    getter id : TypeId
    # Mutable only so an implicitly created namespace (from `class A::B`
    # before `A` is seen) can take the kind of its later real declaration.
    property kind : TypeKind
    getter name : String
    getter full_name : String
    getter namespace : TypeId?
    getter sites = [] of Site
    getter types = {} of String => TypeId
    # Non-type members (defs, macros, constants, ivars, ...) by name.
    getter members = Hash(String, Array(Site)).new { |h, k| h[k] = [] of Site }
    getter type_params = [] of String
    # Raw superclass / include / extend texts with the site they come from;
    # resolved lazily by `DefMap`.
    getter superclass_refs = [] of {String, Site}
    getter include_refs = [] of {String, Site}
    getter extend_refs = [] of {String, Site}
    property? private_type = false

    def initialize(@id, @kind, @name, @full_name, @namespace)
    end

    def each_member_site(& : Site ->) : Nil
      @members.each_value { |sites| sites.each { |s| yield s } }
    end

    def doc : String?
      @sites.each { |s| (d = s.item.doc) && return d }
      nil
    end
  end

  # Workspace-wide merged declaration index.
  #
  # Built from per-file `ItemTree`s. Path lookup follows the compiler
  # (semantic/path_lookup.cr): own types, then self-name, then ancestors,
  # then the enclosing namespace for the first segment only. Conditional
  # items whose flags evaluate to false for the target are skipped.
  class DefMap
    getter types = [] of TypeInfo
    getter flags : Set(String)
    # Top-level non-type items (top-level defs, macros, constants).
    @ancestors_cache = {} of TypeId => Array(TypeId)

    PROGRAM = TypeId.new(0)

    def initialize(@flags : Set(String) = Set(String).new)
      @types << TypeInfo.new(PROGRAM, TypeKind::Program, "", "", nil)
    end

    def program : TypeInfo
      @types[0]
    end

    def [](id : TypeId) : TypeInfo
      @types[id.value]
    end

    # Adds every visible item of one file.
    def add_file(file : FileId, tree : Items::ItemTree) : Nil
      @ancestors_cache.clear
      @namespace_sites = nil
      @subtypes_index = nil
      @path_cache.clear
      tree.items.each { |item| add_item(file, item, PROGRAM) }
      tree.mixins.each do |m|
        next if Items::Cond.all(m.conditions, @flags) == false
        site = Site.new(file, Items::Item.new(Items::ItemKind::Module, m.path, m.range, m.range))
        (m.extend ? program.extend_refs : program.include_refs) << {m.path, site}
      end
      # Declaring the file's types looked up paths, which cached ancestors
      # before this file's includes were known.
      @ancestors_cache.clear
      @path_cache.clear
    end

    # Item positions moved in place (`Item#move_to`); drops what caches
    # them. Declarations are unchanged, so lookups stay valid.
    def positions_changed : Nil
      @namespace_sites = nil
    end

    private def add_item(file : FileId, item : Items::Item, ns : TypeId) : Nil
      return if Items::Cond.all(item.conditions, @flags) == false
      site = Site.new(file, item)

      if item.kind.namespace? || item.kind.alias? || item.kind.type_def?
        target = declare_type(item, ns)
        info = self[target]
        info.sites << site
        info.private_type = true if item.visibility.private?
        if h = item.header
          info.type_params.concat(h.type_params) if info.type_params.empty?
          h.superclass.try { |s| info.superclass_refs << {s, site} }
        end
        item.includes.each { |i| info.include_refs << {i, site} }
        item.extends.each { |e| info.extend_refs << {e, site} }
        item.children.each { |child| add_item(file, child, target) }
      else
        self[ns].members[member_key(item)] << site
      end
    end

    # Adds a member that has no source declaration of its own (compiler
    # facts). *file* is where it was generated.
    # Members do not affect ancestors or paths, so no cache is cleared.
    def add_synthetic(owner : TypeId, file : FileId, item : Items::Item) : Nil
      self[owner].members[member_key(item)] << Site.new(file, item)
    end

    # Class-level defs (`def self.x`) live under a distinct key.
    def self.member_key(name : String, class_level : Bool) : String
      class_level ? "self.#{name}" : name
    end

    private def member_key(item : Items::Item) : String
      sig = item.signature
      DefMap.member_key(item.name, !!(sig && sig.receiver))
    end

    # Finds or creates the type for a declaration. `class A::B` inside `X`
    # declares B under `X::A` (compiler resolves `A` from X outwards; we
    # create intermediate namespaces when missing).
    private def declare_type(item : Items::Item, ns : TypeId) : TypeId
      h = item.header
      path = h ? h.path : [item.name]
      cur = (h && h.global) ? PROGRAM : ns
      path.each_with_index do |seg, i|
        last = i == path.size - 1
        if i == 0 && !last
          cur = lookup_path_item(seg, cur, lookup_self: true, lookup_in_namespace: true) || child_type(cur, seg, TypeKind::Module)
        else
          kind = last ? TypeKind.from(item.kind) : TypeKind::Module
          cur = child_type(cur, seg, kind, declaring: last)
        end
      end
      cur
    end

    private def child_type(ns : TypeId, name : String, kind : TypeKind, declaring = false) : TypeId
      parent = self[ns]
      if found = parent.types[name]?
        info = self[found]
        info.kind = kind if declaring && info.sites.empty?
        return found
      end
      begin
        id = TypeId.new(@types.size)
        full = parent.full_name.empty? ? name : "#{parent.full_name}::#{name}"
        @types << TypeInfo.new(id, kind, name, full, ns)
        parent.types[name] = id
        id
      end
    end

    # -- lookup ---------------------------------------------------------------

    # Resolves a type path as written (e.g. `Foo::Bar`, `::IO`, `Array(T)`)
    # from the namespace *from*. Generic arguments are ignored.
    @path_cache = {} of {String, TypeId} => TypeId?

    def lookup_path(text : String, from : TypeId = PROGRAM) : TypeId?
      key = {text, from}
      return @path_cache[key] if @path_cache.has_key?(key)
      @path_cache[key] = lookup_path_uncached(text, from)
    end

    private def lookup_path_uncached(text : String, from : TypeId) : TypeId?
      lookup_path_raw(text, from).try { |id| resolve_alias(id) }
    end

    # Like `lookup_path`, but an alias stays the alias (navigation: the
    # user wrote `Env`, not `Hash(String, String)`).
    def lookup_path_raw(text : String, from : TypeId = PROGRAM) : TypeId?
      path = DefMap.strip_generics(text)
      global = path.starts_with?("::")
      names = path.lchop("::").split("::")
      return nil if names.empty? || names.any?(&.empty?)
      cur = global ? PROGRAM : from
      names.each_with_index do |name, i|
        first = i == 0
        cur = lookup_path_item(name, cur, lookup_self: first, lookup_in_namespace: first) || return nil
      end
      cur
    end

    def lookup_path_item(name : String, from : TypeId, *, lookup_self : Bool, lookup_in_namespace : Bool) : TypeId?
      info = self[from]
      if found = info.types[name]?
        return found
      end
      return from if lookup_self && from != PROGRAM && info.name == name
      ancestors(from).each do |anc|
        next if anc == from
        if found = self[anc].types[name]?
          return found
        end
      end
      if lookup_in_namespace && (ns = info.namespace)
        return lookup_path_item(name, ns, lookup_self: false, lookup_in_namespace: true)
      end
      nil
    end

    # Follows `alias A = B` to B when B resolves.
    def resolve_alias(id : TypeId, depth = 0) : TypeId
      info = self[id]
      return id unless info.kind.alias? && depth < 8
      site = info.sites.first? || return id
      target = site.item.detail || return id
      ns = info.namespace || PROGRAM
      found = lookup_path(target, ns)
      found && found != id ? resolve_alias(found, depth + 1) : id
    end

    # Superclass, if declared and resolvable.
    def superclass(id : TypeId) : TypeId?
      info = self[id]
      ns = info.namespace || PROGRAM
      info.superclass_refs.each do |(text, _)|
        if found = lookup_path(text, ns)
          return found unless found == id
        end
      end
      implicit_superclass(info)
    end

    # Superclasses the compiler wires up itself (program.cr) rather than in
    # source: Object > Reference / Value > Struct, Number, Enum, ...
    BUILTIN_SUPERCLASSES = {
      "Reference" => "Object", "Value" => "Object", "Struct" => "Value", "Number" => "Value",
      "Int" => "Number", "Float" => "Number", "Nil" => "Value", "Bool" => "Value", "Char" => "Value",
      "Symbol" => "Value", "Pointer" => "Struct", "Tuple" => "Struct", "NamedTuple" => "Struct",
      "StaticArray" => "Struct", "Proc" => "Struct", "Enum" => "Value", "Union" => "Value",
      "Int8" => "Int", "Int16" => "Int", "Int32" => "Int", "Int64" => "Int", "Int128" => "Int",
      "UInt8" => "Int", "UInt16" => "Int", "UInt32" => "Int", "UInt64" => "Int", "UInt128" => "Int",
      "Float32" => "Float", "Float64" => "Float", "String" => "Reference",
    }

    private def implicit_superclass(info : TypeInfo) : TypeId?
      return nil if info.full_name == "Object"
      name = if builtin = BUILTIN_SUPERCLASSES[info.full_name]?
               builtin
             else
               case info.kind
               when .class? then "Reference"
               when .struct? then "Struct"
               when .enum?  then "Enum"
               else              nil
               end
             end
      return nil unless name && info.full_name != name
      found = program.types[name]?
      found == info.id ? nil : found
    end

    # Included modules, resolved, in declaration order.
    def includes(id : TypeId) : Array(TypeId)
      info = self[id]
      if id == PROGRAM
        # Top-level `include M`: resolve M among the program's own types
        # (`lookup_path` from the program would ask for the program's
        # ancestors, i.e. this list, and stop at the cycle guard).
        return info.include_refs.compact_map { |(text, _)| program_path(text) }.uniq
      end
      ns = info.namespace || PROGRAM
      info.include_refs.compact_map do |(text, _)|
        lookup_path(text, id) || lookup_path(text, ns)
      end.uniq
    end

    # `Foo::Bar` from the top level without the program's includes.
    private def program_path(text : String) : TypeId?
      names = DefMap.strip_generics(text).lchop("::").split("::")
      cur = PROGRAM
      names.each { |n| cur = self[cur].types[n]? || return nil }
      resolve_alias(cur)
    end

    # Extended modules; `extend self` resolves to the type itself.
    def extends(id : TypeId) : Array(TypeId)
      info = self[id]
      info.extend_refs.compact_map do |(text, _)|
        next id if text == "self"
        id == PROGRAM ? program_path(text) : lookup_path(text, id)
      end.uniq
    end

    # Linearised ancestors, nearest first, starting with *id* itself:
    # included modules (last included first) precede the superclass chain,
    # like Crystal's method lookup.
    def ancestors(id : TypeId) : Array(TypeId)
      if cached = @ancestors_cache[id]?
        return cached
      end
      # Guard against cycles while computing.
      @ancestors_cache[id] = [id]
      result = [id]
      seen = Set{id}
      add = ->(t : TypeId) do
        ancestors(t).each { |a| result << a if seen.add?(a) }
      end
      includes(id).reverse_each { |m| add.call(m) }
      if sup = superclass(id)
        add.call(sup)
      end
      @ancestors_cache[id] = result
    end

    @subtypes_index : Hash(TypeId, Array(TypeId))? = nil

    # Direct subclasses / includers (for type hierarchy).
    def subtypes(id : TypeId) : Array(TypeId)
      index = @subtypes_index ||= begin
        h = Hash(TypeId, Array(TypeId)).new { |hh, k| hh[k] = [] of TypeId }
        @types.each do |t|
          next if t.kind.alias? || t.kind.type_def? || t.id == PROGRAM
          parents = includes(t.id)
          superclass(t.id).try { |sup| parents << sup }
          parents.uniq.each { |p| h[p] << t.id unless p == t.id }
        end
        h
      end
      index[id]? || [] of TypeId
    end

    # Every type that has *id* as an ancestor (excluding *id*), breadth first.
    def descendants(id : TypeId) : Array(TypeId)
      seen = Set{id}
      result = [] of TypeId
      queue = [id]
      while cur = queue.shift?
        subtypes(cur).each do |s|
          next unless seen.add?(s)
          result << s
          queue << s
        end
      end
      result
    end

    # The namespace enclosing a byte offset of a file: the innermost type
    # whose site in *file* covers *offset*.
    def namespace_at(file : FileId, offset : UInt32) : TypeId
      best = PROGRAM
      best_size = UInt32::MAX
      namespace_sites(file).each do |(range, id)|
        next unless range.touches?(offset)
        if range.size < best_size
          best, best_size = id, range.size
        end
      end
      best
    end

    @namespace_sites : Hash(FileId, Array({TextRange, TypeId}))? = nil

    # Namespace declaration ranges per file (built on first use).
    private def namespace_sites(file : FileId) : Array({TextRange, TypeId})
      index = @namespace_sites ||= begin
        h = Hash(FileId, Array({TextRange, TypeId})).new { |hh, k| hh[k] = [] of {TextRange, TypeId} }
        @types.each do |t|
          next if t.kind.alias? || t.kind.type_def?
          t.sites.each { |site| h[site.file] << {site.item.range, t.id} }
        end
        h
      end
      index[file]? || [] of {TextRange, TypeId}
    end

    # Members named *name* visible on *id*, nearest ancestor first.
    def lookup_member(id : TypeId, name : String) : Array(Site)
      result = [] of Site
      ancestors(id).each do |anc|
        if sites = self[anc].members[name]?
          result.concat(sites)
        end
      end
      result
    end

    # Removes generic arguments: `Array(Int32)` → `Array`, `Foo::Bar(T)::Baz`
    # → `Foo::Bar::Baz`; trailing `?`, `*`, `.class` are dropped.
    def self.strip_generics(text : String) : String
      depth = 0
      String.build do |io|
        text.each_char do |c|
          case c
          when '(' then depth += 1
          when ')' then depth -= 1
          else          io << c if depth == 0
          end
        end
      end.strip.rchop(".class").rstrip("?*")
    end
  end
end
