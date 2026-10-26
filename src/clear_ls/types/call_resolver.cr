require "./type_expr"

module ClearLS::Types
  # Candidate methods for a call on a receiver type.
  record MethodMatch, site : Semantics::Site, owner : Semantics::TypeId, bindings : Hash(String, TyId)

  # One call argument as seen by the resolver.
  record CallArg, type : TyId, splat : Bool = false, literal : Syntax::Kind? = nil

  # Shape and argument types of a call site.
  record CallSite,
    args : Array(CallArg),
    named : Array({String, CallArg}),
    double_splat : Bool,
    block : Bool

  # Three-valued answer: eliminate a candidate only on proof.
  enum Compatibility
    Compatible
    Unknown
    Incompatible

    def worst(other : Compatibility) : Compatibility
      value >= other.value ? self : other
    end

    def best(other : Compatibility) : Compatibility
      value <= other.value ? self : other
    end
  end

  enum ResolutionKind
    Unique                 # one viable candidate
    MultipleRuntimeTargets # union-typed receiver/arguments dispatch to several
    Ambiguous              # several viable candidates, not enough type evidence
    NameOnly               # methods with this name exist but none fits the call
    Unresolved             # no method with this name
  end

  # A candidate bound to a call: which parameter each argument goes to.
  class CallCandidate
    getter match : MethodMatch
    # `self` for the candidate's signature (receiver instance type).
    getter self_type : TyId
    # Parameter index per positional argument (nil after a splat argument).
    getter arg_params : Array(Int32?)
    # Parameter index per named argument (a double splat collects extras).
    getter named_params : Array(Int32?)
    # Unknown when the call's splat/double-splat arguments hide the arity.
    getter structural : Compatibility
    # Best type compatibility over the call's runtime type combinations.
    property compat = Compatibility::Incompatible
    # Parsed restrictions by parameter index (nil: unrestricted).
    getter restrictions = {} of Int32 => TyId?
    # Argument types of the call (positional, then named).
    property arg_types = [] of TyId
    # Names of the call's named arguments (same order as `named_params`).
    property named_names = [] of String

    def initialize(@match, @self_type, @arg_params, @named_params, @structural)
    end

    def item : Items::Item
      match.site.item
    end

    def signature : Items::Signature?
      item.signature
    end
  end

  struct CallResolution
    getter kind : ResolutionKind
    # Viable candidates (empty for NameOnly / Unresolved).
    getter candidates : Array(CallCandidate)
    # Every method with the call's name on the receiver, for display when
    # nothing fits (unfinished calls).
    getter family : Array(MethodMatch)

    def initialize(@kind, @candidates, @family)
    end

    def self.unresolved : CallResolution
      new(ResolutionKind::Unresolved, [] of CallCandidate, [] of MethodMatch)
    end

    def matches : Array(MethodMatch)
      candidates.map(&.match)
    end
  end

  # Overload resolution (architecture §20): structural argument binding,
  # three-valued type compatibility, bounded specificity ranking.
  #
  # Union-typed arguments are expanded (up to `MAX_COMBOS` combinations) and
  # resolved per combination, like the compiler's runtime dispatch; the
  # winners of every combination are the call's targets. Unknown argument
  # types keep every structurally viable candidate that a definitely
  # matching, at least as specific candidate does not shadow.
  class CallResolver
    MAX_COMBOS     = 16
    MAX_CANDIDATES = 32

    # Autocasting allowed in `matches` (off for exact-match passes and
    # specificity).
    @cast = true

    def initialize(@table : TypeTable)
    end

    def map : Semantics::DefMap
      @table.def_map
    end

    # *groups*: candidates per receiver member type (`self` of each group).
    def resolve(groups : Array({TyId, Array(MethodMatch)}), site : CallSite) : CallResolution
      family = groups.flat_map(&.[1])
      return CallResolution.unresolved if family.empty?
      winners = [] of CallCandidate
      all_unique = true
      groups.each do |(self_t, matches)|
        bound = matches.first(MAX_CANDIDATES).compact_map { |m| bind(m, self_t, site) }
        group_winners, unique = rank(bound, site)
        all_unique &&= unique
        winners.concat(group_winners)
      end
      kind = if winners.empty?
               ResolutionKind::NameOnly
             elsif winners.size == 1
               ResolutionKind::Unique
             elsif all_unique
               ResolutionKind::MultipleRuntimeTargets
             else
               ResolutionKind::Ambiguous
             end
      CallResolution.new(kind, winners, family)
    end

    # -- structural binding ---------------------------------------------------------

    # Binds arguments to parameters, or nil when the call cannot fit.
    def bind(m : MethodMatch, self_t : TyId, site : CallSite) : CallCandidate?
      c = bind_params(m, self_t, site) || return nil
      c.arg_types = site.args.map(&.type) + site.named.map(&.[1].type)
      c.named_names = site.named.map(&.[0])
      c
    end

    private def bind_params(m : MethodMatch, self_t : TyId, site : CallSite) : CallCandidate?
      sig = m.site.item.signature
      unless sig
        n = site.args.size
        return CallCandidate.new(m, self_t, Array(Int32?).new(n, nil), Array(Int32?).new(site.named.size, nil), Compatibility::Unknown)
      end
      params = sig.params
      structural = Compatibility::Compatible
      block_p = params.index(&.kind.block?)
      # A block parameter makes the block mandatory; without one a block is
      # an error (all stdlib defs that yield declare `&`).
      return nil if site.block != !block_p.nil?

      splat_idx = params.index(&.kind.splat?)
      positional = params.each_index.select { |i| params[i].kind.positional? && (splat_idx.nil? || i < splat_idx) }.to_a
      splat_named = splat_idx && params[splat_idx].name ? splat_idx : nil
      dsplat = params.index(&.kind.double_splat?)

      bound = Set(Int32).new
      arg_params = [] of Int32?
      pi = 0
      hidden_positional = false
      site.args.each do |a|
        if a.splat || hidden_positional
          # `*xs`: unknown count from here on.
          hidden_positional = true
          structural = Compatibility::Unknown
          arg_params << nil
          next
        end
        if pi < positional.size
          arg_params << positional[pi]
          bound << positional[pi]
          pi += 1
        elsif splat_named
          arg_params << splat_named
        else
          return nil
        end
      end

      named_params = [] of Int32?
      site.named.each do |(name, _)|
        idx = params.index { |p| p.kind.positional? && p.call_name == name }
        if idx
          return nil if bound.includes?(idx) && !hidden_positional
          bound << idx
          named_params << idx
        elsif dsplat
          named_params << dsplat
        else
          return nil
        end
      end

      params.each_with_index do |p, i|
        next unless p.kind.positional? && p.default.nil? && !bound.includes?(i)
        # Could still come from `*xs` (positional) or `**opts` (by name).
        named_only = splat_idx && i > splat_idx
        if site.double_splat || (hidden_positional && !named_only)
          structural = Compatibility::Unknown
        else
          return nil
        end
      end
      CallCandidate.new(m, self_t, arg_params, named_params, structural)
    end

    # -- ranking --------------------------------------------------------------------

    # Winners over all argument type combinations, and whether every
    # combination had exactly one definite winner.
    private def rank(cands : Array(CallCandidate), site : CallSite) : {Array(CallCandidate), Bool}
      return {cands, false} if cands.empty?
      winners = [] of CallCandidate
      unique = true
      combos(site).each do |types|
        # A candidate the arguments fit without autocasting wins over those
        # that need a cast (`f(x : Int64)` vs `f(x)` with `1` picks `f(x)`);
        # several cast-only fits stay ambiguous, like the compiler's error.
        comps = viable(cands, site, types, cast: false)
        comps = viable(cands, site, types, cast: true) unless comps.any?(&.[1].compatible?)
        definite = comps.select(&.[1].compatible?).map(&.[0])
        kept = comps.reject do |(c, _)|
          definite.any? { |d| d != c && shadows?(d, c, cands, site) } ||
            comps.any? { |(d, _)| d != c && overrides?(d, c, cands, site) }
        end
        kept.each do |(c, k)|
          c.compat = c.compat.best(k)
          winners << c unless winners.includes?(c)
        end
        unique = false unless kept.size == 1 && kept[0][1].compatible?
      end
      # Declaration order, not combination order.
      {winners.sort_by! { |c| cands.index!(c) }, unique}
    end

    private def viable(cands : Array(CallCandidate), site : CallSite, types : Array(TyId), cast : Bool) : Array({CallCandidate, Compatibility})
      without_cast(!cast) do
        cands.compact_map do |c|
          k = compat(c, site, types)
          k.incompatible? ? nil : {c, k}
        end
      end
    end

    private def without_cast(off : Bool = true, &)
      saved = @cast
      @cast = false if off
      begin
        yield
      ensure
        @cast = saved
      end
    end

    # Does definite candidate *d* hide *c*: at least as specific, and
    # strictly more specific or earlier (nearer ancestor: an override)?
    private def shadows?(d : CallCandidate, c : CallCandidate, order : Array(CallCandidate), site : CallSite) : Bool
      return false unless at_least_as_specific?(d, c, site)
      !at_least_as_specific?(c, d, site) || order.index!(d) < order.index!(c)
    end

    # *d* redefines *c* in a nearer ancestor with the same restrictions
    # (an override or an abstract def's implementation): whatever the
    # argument types, *c* is never called.
    private def overrides?(d : CallCandidate, c : CallCandidate, order : Array(CallCandidate), site : CallSite) : Bool
      return false unless d.match.owner != c.match.owner && order.index!(d) < order.index!(c)
      at_least_as_specific?(d, c, site) && at_least_as_specific?(c, d, site)
    end

    # Every argument's restriction in *a* is within *b*'s (no restriction is
    # the widest).
    private def at_least_as_specific?(a : CallCandidate, b : CallCandidate, site : CallSite) : Bool
      pairs = a.arg_params.zip(b.arg_params) + a.named_params.zip(b.named_params)
      pairs.all? do |(pa, pb)|
        rb = pb.try { |i| restriction(b, i) }
        next true if rb.nil?
        ra = pa.try { |i| restriction(a, i) }
        next false if ra.nil?
        without_cast { @table.members(ra).all? { |m| matches(m, rb, nil).compatible? } }
      end
    end

    # Argument type combinations: union members expanded when bounded.
    private def combos(site : CallSite) : Array(Array(TyId))
      all = site.args.map(&.type) + site.named.map(&.[1].type)
      choices = all.map { |t| @table.members(t) }
      count = choices.reduce(1) { |acc, c| acc * c.size }
      return [all] if count > MAX_COMBOS || count == 1
      result = [[] of TyId]
      choices.each do |opts|
        result = result.flat_map { |prefix| opts.map { |o| prefix + [o] } }
      end
      result
    end

    # Compatibility of *c* with one type combination.
    def compat(c : CallCandidate, site : CallSite, types : Array(TyId)) : Compatibility
      result = c.structural
      c.arg_params.each_with_index do |pi, i|
        next unless pi
        r = restriction(c, pi) || next
        result = result.worst(matches(types[i], r, site.args[i].literal))
        return result if result.incompatible?
      end
      c.named_params.each_with_index do |pi, i|
        next unless pi
        next if c.signature.try { |s| s.params[pi].kind.double_splat? }
        r = restriction(c, pi) || next
        result = result.worst(matches(types[site.args.size + i], r, site.named[i][1].literal))
        return result if result.incompatible?
      end
      result
    end

    # Parsed restriction of parameter *pi* with the receiver's generic
    # bindings applied; nil when unrestricted.
    def restriction(c : CallCandidate, pi : Int32) : TyId?
      return c.restrictions[pi] if c.restrictions.has_key?(pi)
      c.restrictions[pi] = begin
        sig = c.signature.not_nil!
        text = sig.params[pi].restriction
        if text
          owner = map[c.match.owner]
          t = TypeExprParser.parse(text, @table, c.match.owner, owner.type_params + sig.free_vars, c.self_type)
          Subst.apply(@table, t, c.match.bindings)
        end
      end
    end

    # `matches` without autocasting: the value already has the
    # restriction's type (summaries bind such params to the argument type).
    def matches_exactly(actual : TyId, restriction : TyId) : Compatibility
      without_cast { matches(actual, restriction, nil) }
    end

    # Does a value of type *actual* satisfy *restriction*?
    def matches(actual : TyId, restriction : TyId, literal : Syntax::Kind?) : Compatibility
      return Compatibility::Unknown if @table.unknown?(actual) || @table.unknown?(restriction)
      a = @table[actual]
      r = @table[restriction]
      return Compatibility::Compatible if a.kind.no_return? || r.kind.type_param?
      if r.kind.union?
        return r.args.reduce(Compatibility::Incompatible) { |acc, m| acc.best(matches(actual, m, literal)) }
      end
      if a.kind.union?
        ks = a.args.map { |m| matches(m, restriction, literal) }
        return Compatibility::Compatible if ks.all?(&.compatible?)
        return Compatibility::Incompatible if ks.all?(&.incompatible?)
        return Compatibility::Unknown
      end
      # Autocasting (skipped in exact passes): numbers, and `:sym` literals
      # to enums.
      if @cast && r.kind.named? && a.kind.named?
        return Compatibility::Compatible if autocast?(a, r, literal)
        return Compatibility::Compatible if literal.try(&.symbol_node?) && map[r.def_id.not_nil!].kind.enum?
      end
      case r.kind
      when .named?
        rid = r.def_id.not_nil!
        return Compatibility::Compatible if map[rid].full_name.in?("Object") || (a.kind.metaclass? && map[rid].full_name == "Class")
        aid = def_of(a) || return Compatibility::Incompatible
        nominal(aid, a.kind.named? ? a.args : [] of TyId, rid, r.args)
      when .metaclass?
        return Compatibility::Incompatible unless a.kind.metaclass?
        matches(a.args[0], r.args[0], nil)
      when .tuple?
        return Compatibility::Incompatible unless a.kind.tuple?
        return Compatibility::Incompatible unless a.args.size == r.args.size
        a.args.zip(r.args).reduce(Compatibility::Compatible) { |acc, (x, y)| acc.worst(matches(x, y, nil)) }
      when .named_tuple?
        a.kind.named_tuple? ? Compatibility::Unknown : Compatibility::Incompatible
      when .proc?
        a.kind.proc? ? Compatibility::Compatible : Compatibility::Incompatible
      else
        Compatibility::Unknown
      end
    end

    private def nominal(aid : Semantics::TypeId, aargs : Array(TyId), rid : Semantics::TypeId, rargs : Array(TyId)) : Compatibility
      if aid == rid
        return Compatibility::Compatible if rargs.empty? || aargs.empty?
        return Compatibility::Unknown unless aargs.size == rargs.size
        return aargs.zip(rargs).reduce(Compatibility::Compatible) { |acc, (x, y)| acc.worst(matches(x, y, nil)) }
      end
      return Compatibility::Incompatible unless map.ancestors(aid).includes?(rid)
      # Mapping generic args through ancestors is not modelled.
      rargs.all? { |x| @table[x].kind.type_param? } ? Compatibility::Compatible : Compatibility::Unknown
    end

    # Nominal type of a structural type (`{Int32}` is a `Tuple`).
    private def def_of(t : Ty) : Semantics::TypeId?
      case t.kind
      when .named?       then t.def_id
      when .tuple?       then map.lookup_path("::Tuple")
      when .named_tuple? then map.lookup_path("::NamedTuple")
      when .proc?        then map.lookup_path("::Proc")
      when .metaclass?   then map.lookup_path("::Class")
      end
    end

    # Number autocasting (autocasting.md, checked against Crystal 1.22):
    # an integer literal casts to any integer or float type, a float
    # literal only to floats (the literal's value is not checked: an
    # out-of-range literal is a compile error that the compiler reports).
    # Other number expressions cast only where no precision is lost:
    # integers to wider integers that hold every value and to floats with
    # enough mantissa, Float32 to Float64.
    def autocast?(a : Ty, r : Ty, literal : Syntax::Kind?) : Bool
      return false if a.def_id == r.def_id
      from = NUMBER_RANKS[map[a.def_id.not_nil!].full_name]? || return false
      to = NUMBER_RANKS[map[r.def_id.not_nil!].full_name]? || return false
      if literal
        return true if literal.integer?
        return to[0] == :float if literal.float_node?
      end
      fk, fbits = from
      tk, tbits = to
      case {fk, tk}
      when {:float, :float} then fbits < tbits
      when {:float, _}      then false
      when {_, :float}      then fbits < (tbits == 32 ? 24 : 53)
      when {:uint, :int}    then fbits < tbits
      when {:int, :uint}    then false
      else                       fbits < tbits
      end
    end

    NUMBER_RANKS = {
      "Int8" => {:int, 8}, "Int16" => {:int, 16}, "Int32" => {:int, 32}, "Int64" => {:int, 64}, "Int128" => {:int, 128},
      "UInt8" => {:uint, 8}, "UInt16" => {:uint, 16}, "UInt32" => {:uint, 32}, "UInt64" => {:uint, 64}, "UInt128" => {:uint, 128},
      "Float32" => {:float, 32}, "Float64" => {:float, 64},
    }

  end
end
