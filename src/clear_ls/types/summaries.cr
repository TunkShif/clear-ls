require "./ty"

module ClearLS::Types
  # On-demand method summaries (architecture §19, tier 2).
  #
  # The summary of a def for one call shape — (def, self type, argument
  # types) — is the result of inferring the def's body with its
  # unrestricted parameters bound to the argument types: the joined return
  # type and the joined type of each `yield` argument.
  #
  # Summaries are computed when a call needs them and cached for the
  # lifetime of the TypeTable (one DefMap generation). Recursion (a def
  # whose summary is being computed is called again, directly or through
  # other defs) answers Pending for the inner call, so the outer summary
  # is built from the non-recursive paths, like a first fixed-point
  # iteration. Results computed while a recursion was cut are only cached
  # for the outermost def of the cycle (inner ones would keep the cut). Budgets bound nesting depth and total work per Typing.
  class Summaries
    # *with_self*: the receiver of `with x yield` (the block's implicit
    # `self` for calls without a receiver), if any.
    record Summary, returns : TyId, yields : Array(TyId), with_self : TyId? = nil

    # (file, def start, file revision, self type, argument types).
    alias Key = {Int32, UInt32, UInt64, Int32, Array(Int32)}

    # Nesting depth of summaries being computed at once. Results are
    # cached, so depth bounds stack use rather than total work.
    MAX_DEPTH = 12
    # Defs summarised per generation before giving up (protects against
    # pathological fan-out in big files; cached entries are free).
    MAX_TOTAL = 20_000
    # Call shapes (argument types, block value) kept per def and receiver;
    # further shapes reuse a coarser one.
    MAX_SHAPES = 16

    getter computed = 0
    getter hits = 0
    # Summaries recomputed later because a cut or budget made them partial.
    getter uncached = 0
    @cache = {} of Key => Summary
    # Summaries being computed, outermost first.
    @stack = [] of Key
    # Lowest stack level a recursion cut referred to while computing the
    # current summary.
    @lowest_cut = Int32::MAX
    @shapes = Hash({ {Int32, UInt32, UInt64}, Int32 }, Int32).new(0)
    @depth = 0

    # Current revision of a file (open buffers change without a DefMap
    # rebuild when only bodies are edited).
    alias RevisionOf = Proc(FileId, UInt64)
    property revision_of : RevisionOf? = nil

    def initialize(@table : TypeTable)
    end

    def unknown_summary : Summary
      Summary.new(@table.unknown, [] of TyId)
    end

    # Summary of the def at *site* for *self_t* and *args* (one type per
    # parameter position of the def; unknown entries leave the declared or
    # unknown type). *compute* infers the body and returns the summary.
    def get(site : Semantics::Site, self_t : TyId, args : Array(TyId), fallback : Array(TyId)? = nil, & : Array(TyId) -> Summary?) : Summary
      rev = @revision_of.try(&.call(site.file)) || 0_u64
      def_key = {site.file.value.to_i32, site.item.range.start, rev}
      # Unknown args carry no information: normalise so shapes are shared.
      args = [] of TyId if args.all? { |a| @table.unknown?(a) }
      # Shape cap per (def, self): each receiver type is its own instance.
      # Over the cap, the caller's coarser *fallback* shape is used, else
      # the unparameterised one.
      shape_key = {def_key, self_t.value}
      if !args.empty? && @shapes[shape_key] >= MAX_SHAPES && !@cache.has_key?(key(def_key, self_t, args))
        args = fallback.try { |f| f.all? { |a| @table.unknown?(a) } ? nil : f } || [] of TyId
      end
      k = key(def_key, self_t, args)
      if cached = @cache[k]?
        @hits += 1
        return cached
      end
      # Recursive call: contributes nothing to the outer summary (Pending
      # vanishes from unions), like the first iteration of a fixed point.
      if level = @stack.index(k)
        # Every summary between the cycle head and here depends on a cut.
        @lowest_cut = Math.min(@lowest_cut, level)
        return Summary.new(@table.pending, [] of TyId)
      end
      if @depth >= MAX_DEPTH || @computed >= MAX_TOTAL
        # Budget answer: the caller's summary is partial; it may be cached
        # (a deeper chain would only be cut again), but not the whole stack.
        return unknown_summary
      end
      @stack << k
      @depth += 1
      @computed += 1
      @shapes[shape_key] += 1 unless args.empty?
      level = @stack.size - 1
      saved_cut = @lowest_cut
      @lowest_cut = Int32::MAX
      begin
        result = (yield args) || unknown_summary
      ensure
        @depth -= 1
        @stack.pop
      end
      cut = @lowest_cut
      # Cached unless a cycle through an outer def was cut beneath us; the
      # cycle head (cut == level) caches its first-iteration result.
      @cache[k] = result if cut >= level
      @lowest_cut = Math.min(saved_cut, cut >= level ? Int32::MAX : cut)
      @uncached += 1 unless cut >= level
      result
    end

    private def key(def_key : {Int32, UInt32, UInt64}, self_t : TyId, args : Array(TyId)) : Key
      {def_key[0], def_key[1], def_key[2], self_t.value, args.map(&.value)}
    end
  end
end
