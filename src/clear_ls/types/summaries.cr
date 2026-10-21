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
  # other defs) answers NoReturn for the inner call, so the outer summary
  # is built from the non-recursive paths, like a first fixed-point
  # iteration. Results computed while a recursion was cut are only cached
  # for the outermost def of the cycle (inner ones would keep the cut). Budgets bound nesting depth and total work per Typing.
  class Summaries
    record Summary, returns : TyId, yields : Array(TyId)

    # (file, def start, file revision, self type, argument types).
    alias Key = {Int32, UInt32, UInt64, Int32, Array(Int32)}

    MAX_DEPTH = 4
    # Defs summarised per generation before giving up (protects against
    # pathological fan-out in big files; cached entries are free).
    MAX_TOTAL = 20_000
    # Argument type combinations kept per def; further shapes reuse the
    # unparameterised summary.
    MAX_SHAPES = 8

    getter computed = 0
    getter hits = 0
    @cache = {} of Key => Summary
    @in_progress = Set(Key).new
    @shapes = Hash({Int32, UInt32, UInt64}, Int32).new(0)
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
    def get(site : Semantics::Site, self_t : TyId, args : Array(TyId), & : Array(TyId) -> Summary?) : Summary
      rev = @revision_of.try(&.call(site.file)) || 0_u64
      def_key = {site.file.value.to_i32, site.item.range.start, rev}
      # Unknown args carry no information: normalise so shapes are shared.
      args = [] of TyId if args.all? { |a| @table.unknown?(a) }
      if !args.empty? && @shapes[def_key] >= MAX_SHAPES && !@cache.has_key?(key(def_key, self_t, args))
        args = [] of TyId
      end
      k = key(def_key, self_t, args)
      if cached = @cache[k]?
        @hits += 1
        return cached
      end
      # Recursive call: contributes nothing to the outer summary (NoReturn
      # vanishes from unions), like the first iteration of a fixed point.
      return Summary.new(@table.no_return, [] of TyId) if @in_progress.includes?(k)
      return unknown_summary if @depth >= MAX_DEPTH || @computed >= MAX_TOTAL
      @in_progress << k
      @depth += 1
      @computed += 1
      @shapes[def_key] += 1 unless args.empty?
      begin
        result = (yield args) || unknown_summary
      ensure
        @depth -= 1
        @in_progress.delete(k)
      end
      @cache[k] = result
    end

    private def key(def_key : {Int32, UInt32, UInt64}, self_t : TyId, args : Array(TyId)) : Key
      {def_key[0], def_key[1], def_key[2], self_t.value, args.map(&.value)}
    end
  end
end
