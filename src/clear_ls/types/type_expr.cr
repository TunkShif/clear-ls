require "./ty"

module ClearLS::Types
  # Parses type expressions as written in restrictions and return types:
  # `Int32`, `Array(String)?`, `A | B`, `{Int32, String}`, `{a: Int32}`,
  # `Int32 -> Nil`, `Foo.class`, `T*`, `UInt8[4]`, `self`, `typeof(...)`.
  #
  # Names resolve through the DefMap from namespace *ns*. Names in
  # *type_params* (e.g. `T` of `Array(T)`, `forall U`) become TypeParams,
  # later substituted by `Subst`. Unresolvable names produce Unknown.
  class TypeExprParser
    def self.parse(text : String, table : TypeTable, ns : Semantics::TypeId,
                   type_params : Enumerable(String) = [] of String, self_type : TyId? = nil) : TyId
      new(text, table, ns, type_params, self_type).run
    end

    @pos = 0

    def initialize(@text : String, @table : TypeTable, @ns : Semantics::TypeId,
                   @type_params : Enumerable(String), @self_type : TyId?)
    end

    def run : TyId
      ty = parse_union
      skip_ws
      @pos == @text.size ? ty : @table.unknown
    rescue IndexError
      @table.unknown
    end

    # union := proc ('|' proc)*
    private def parse_union : TyId
      first = parse_proc
      members = [first]
      while accept('|')
        members << parse_proc
      end
      members.size == 1 ? first : @table.union(members)
    end

    # proc := (postfix (',' postfix)*)? '->' postfix? | postfix
    private def parse_proc : TyId
      skip_ws
      if peek_str("->")
        @pos += 2
        return @table.proc([] of TyId, parse_proc_return)
      end
      first = parse_postfix
      skip_ws
      if peek == ',' && proc_ahead?
        params = [first]
        while accept(',')
          params << parse_postfix
        end
        skip_ws
        expect_str("->")
        return @table.proc(params, parse_proc_return)
      end
      if peek_str("->")
        @pos += 2
        return @table.proc([first], parse_proc_return)
      end
      first
    end

    private def parse_proc_return : TyId
      skip_ws
      return @table.named!("Nil") if @pos >= @text.size || peek.in?(')', ',', '}', '|')
      parse_postfix
    end

    # Is there a `->` at this nesting level before the expression ends?
    private def proc_ahead? : Bool
      depth = 0
      i = @pos
      while i < @text.size
        c = @text[i]
        case c
        when '(', '{', '[' then depth += 1
        when ')', '}', ']'
          return false if depth == 0
          depth -= 1
        when '-'
          return true if depth == 0 && @text[i + 1]? == '>'
        when '|'
          return false if depth == 0
        end
        i += 1
      end
      false
    end

    # postfix := primary ('?' | '*' | '**' | '[' N ']' | '.class')*
    private def parse_postfix : TyId
      ty = parse_primary
      loop do
        skip_ws
        if accept_raw('?')
          ty = @table.nilable(ty)
        elsif peek_str("**")
          @pos += 2
          ty = @table.named?("Pointer", [@table.named?("Pointer", [ty]) || @table.unknown]) || @table.unknown
        elsif accept_raw('*')
          ty = @table.named?("Pointer", [ty]) || @table.unknown
        elsif peek == '['
          @pos += 1
          skip_until(']')
          ty = @table.named?("StaticArray", [ty]) || @table.unknown
        elsif peek_str(".class")
          @pos += 6
          ty = @table.metaclass(ty)
        else
          break
        end
      end
      ty
    end

    private def parse_primary : TyId
      skip_ws
      c = peek
      if c == '('
        @pos += 1
        inner = parse_union
        expect(')')
        return inner
      end
      return parse_tuple if c == '{'
      if c == '_' && !ident_char?(@text[@pos + 1]?)
        @pos += 1
        return @table.unknown
      end
      if peek_str("typeof(")
        @pos += 7
        skip_until(')')
        return @table.unknown
      end
      if peek_str("self") && !ident_char?(@text[@pos + 4]?)
        @pos += 4
        return @self_type || @table.unknown
      end
      if c == '*' # splat in generic args: `Tuple(*T)`
        @pos += 1
        return parse_postfix
      end
      parse_path
    end

    private def parse_tuple : TyId
      expect('{')
      skip_ws
      if accept('}')
        return @table.tuple([] of TyId)
      end
      # Named tuple if the first entry is `name:` (not `::`).
      named = !!(@text[@pos..] =~ /\A("[^"]*"|[a-z_]\w*)\s*:(?!:)/)
      names = [] of String
      elems = [] of TyId
      loop do
        skip_ws
        if named
          key = @text[@pos..][/\A("[^"]*"|[a-z_]\w*)/]
          @pos += key.size
          expect(':')
          names << key.strip('"')
        end
        elems << parse_union
        skip_ws
        break unless accept(',')
      end
      expect('}')
      named ? @table.named_tuple(names, elems) : @table.tuple(elems)
    end

    # path := '::'? Const ('::' Const)* generic_args?
    private def parse_path : TyId
      start = @pos
      @pos += 2 if peek_str("::")
      loop do
        raise IndexError.new unless (c = peek) && c.uppercase?
        while ident_char?(@text[@pos]?)
          @pos += 1
        end
        break unless peek_str("::") && @text[@pos + 2]?.try(&.uppercase?)
        @pos += 2
      end
      path = @text[start...@pos]
      args = [] of TyId
      if peek == '('
        @pos += 1
        skip_ws
        unless accept(')')
          loop do
            skip_ws
            args << (number_ahead? ? skip_number : parse_union)
            skip_ws
            break unless accept(',')
          end
          expect(')')
        end
      end

      if !path.includes?("::") && @type_params.includes?(path)
        return @table.type_param(path)
      end
      # `Tuple(A, B)` is the structural tuple `{A, B}` (args may be splats
      # or type params, which stay nominal).
      if path.lchop("::") == "Tuple" && !args.empty? && !@text[start...@pos].includes?('*') &&
         args.none? { |a| @table[a].kind.type_param? }
        return @table.tuple(args)
      end
      # `Proc(A, R)` is the structural proc `A -> R` (`Proc(*T, R)` and
      # params stay nominal).
      if path.lchop("::") == "Proc" && !args.empty? && !@text[start...@pos].includes?('*') &&
         args.none? { |a| @table[a].kind.type_param? }
        return @table.proc(args[0...-1], args.last)
      end
      # Built in, not declared in the stdlib.
      return @table.no_return if path.in?("NoReturn", "::NoReturn") && args.empty?
      def_id = @table.def_map.lookup_path(path, @ns) || return @table.unknown
      # lookup_path follows aliases to their target type, dropping generic
      # args (`alias IntP = Pointer(Int32)` → Pointer): parse the alias's
      # target text instead.
      if args.empty? && (raw = unresolved_alias(path)) && raw != def_id
        rinfo = @table.def_map[raw]
        if target = rinfo.sites.first?.try(&.item.detail)
          return @table.alias_target(raw) { TypeExprParser.parse(target, @table, rinfo.namespace || Semantics::DefMap::PROGRAM) }
        end
      end
      info = @table.def_map[def_id]
      if info.kind.alias? && args.empty? && (target = info.sites.first?.try(&.item.detail))
        # `alias Stdio = Redirect | IO`: the aliased type (recursive aliases
        # stay nominal).
        return @table.alias_target(def_id) do
          TypeExprParser.parse(target, @table, info.namespace || Semantics::DefMap::PROGRAM)
        end
      end
      @table.named(def_id, args)
    end

    # The alias item *path* names (not followed), if it is one.
    private def unresolved_alias(path : String) : Semantics::TypeId?
      map = @table.def_map
      names = path.lchop("::").split("::")
      cur = path.starts_with?("::") ? Semantics::DefMap::PROGRAM : @ns
      names.each_with_index do |n, i|
        cur = map.lookup_path_item(n, cur, lookup_self: i == 0, lookup_in_namespace: i == 0) || return nil
      end
      map[cur].kind.alias? ? cur : nil
    end

    # Numeric generic args (`StaticArray(UInt8, 4)`) are kept as Unknown.
    private def number_ahead? : Bool
      !!peek.try(&.ascii_number?)
    end

    private def skip_number : TyId
      while peek.try(&.ascii_number?) || peek == '_'
        @pos += 1
      end
      @table.unknown
    end

    private def skip_until(close : Char) : Nil
      depth = 0
      while c = peek
        @pos += 1
        if c == '('
          depth += 1
        elsif c == close && depth == 0
          return
        elsif c == ')'
          depth -= 1
        end
      end
    end

    private def ident_char?(c : Char?) : Bool
      !!c && (c.alphanumeric? || c == '_')
    end

    private def peek : Char?
      @text[@pos]?
    end

    private def peek_str(s : String) : Bool
      @text[@pos, s.size]? == s
    end

    private def skip_ws : Nil
      while (c = peek) && c.whitespace?
        @pos += 1
      end
    end

    private def accept(c : Char) : Bool
      skip_ws
      accept_raw(c)
    end

    private def accept_raw(c : Char) : Bool
      return false unless peek == c
      @pos += 1
      true
    end

    private def expect(c : Char) : Nil
      raise IndexError.new unless accept(c)
    end

    private def expect_str(s : String) : Nil
      skip_ws
      raise IndexError.new unless peek_str(s)
      @pos += s.size
    end
  end

  # Substitutes TypeParams by name.
  module Subst
    def self.apply(table : TypeTable, id : TyId, bindings : Hash(String, TyId)) : TyId
      return id if bindings.empty?
      t = table[id]
      case t.kind
      when .type_param?
        bindings[t.param.not_nil!]? || id
      when .named?
        return id if t.args.empty?
        table.named(t.def_id.not_nil!, t.args.map { |a| apply(table, a, bindings) })
      when .union?
        table.union(t.args.map { |a| apply(table, a, bindings) })
      when .tuple?
        table.tuple(t.args.map { |a| apply(table, a, bindings) })
      when .named_tuple?
        table.named_tuple(t.names, t.args.map { |a| apply(table, a, bindings) })
      when .proc?
        args = t.args.map { |a| apply(table, a, bindings) }
        table.proc(args[0...-1], args.last)
      when .metaclass?
        table.metaclass(apply(table, t.args[0], bindings))
      else
        id
      end
    end

    # Any TypeParam left in *id*?
    def self.open?(table : TypeTable, id : TyId) : Bool
      t = table[id]
      t.kind.type_param? || t.args.any? { |a| open?(table, a) }
    end

    # Binds TypeParams in *pattern* against *actual* (structural, best
    # effort). `Array(T)` ~ `Array(String)` → T = String.
    def self.unify(table : TypeTable, pattern : TyId, actual : TyId, out bindings : Hash(String, TyId)) : Nil
      p = table[pattern]
      a = table[actual]
      case p.kind
      when .type_param?
        name = p.param.not_nil!
        bindings[name] = bindings[name]?.try { |prev| table.union([prev, actual]) } || actual
      when .named?
        if a.kind.named? && a.def_id == p.def_id
          p.args.zip?(a.args) { |pp, aa| unify(table, pp, aa, bindings) if aa }
        elsif a.kind.tuple? && table.def_map[p.def_id.not_nil!].full_name == "Tuple"
          # `Tuple(K, V)` written as a generic ~ `{String, Int32}`.
          p.args.zip?(a.args) { |pp, aa| unify(table, pp, aa, bindings) if aa }
        end
      when .tuple?, .proc?
        if a.kind == p.kind
          p.args.zip?(a.args) { |pp, aa| unify(table, pp, aa, bindings) if aa }
        end
      when .metaclass?
        # `type : T.class` ~ `Float32` (the constant): T = Float32.
        unify(table, p.args[0], a.args[0], bindings) if a.kind.metaclass?
      when .union?
        # `T?` ~ `String?` or `T?` ~ `String`: bind T to the non-nil part.
        non_nil = p.args.reject { |m| table.nil_type?(m) }
        if non_nil.size == 1
          unify(table, non_nil[0], table.without_nil(actual), bindings)
        end
      end
    end
  end
end
