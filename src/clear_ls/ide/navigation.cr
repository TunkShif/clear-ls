require "./type_info"
require "./analysis"

module ClearLS::IDE
  # A method declaration for call hierarchy.
  record CallItem, site : Semantics::Site, owner : Semantics::TypeId

  # An outgoing call from one def: the targets and where they are called.
  record OutgoingCall, target : CallItem, ranges : Array(TextRange)

  # Implementation lookup and outgoing call hierarchy.
  #
  # Implementations of a method are same-named defs in subtypes of the
  # owner (overrides, implementations of an abstract def, module methods
  # implemented by includers). Implementations of a type are its
  # transitive subtypes and includers. Incoming calls come from
  # workspace references (`References`, LSP `incoming_calls`).
  class Navigation
    MAX_RESULTS = 200

    def initialize(@state : FileState, @bodies : Bodies, @typing : Typing, @analysis : Analysis)
    end

    private def map : Semantics::DefMap
      @typing.def_map
    end

    # -- implementation ---------------------------------------------------------------

    def implementations(offset : UInt32) : Array(Semantics::Site)
      if item = def_item_at(offset)
        return method_implementations(item[0], item[1])
      end
      if hit = TypeInfo.new(@state, @bodies, @typing).call_at(offset)
        _, matches, _ = hit
        return matches.flat_map { |m| [m.site] + method_implementations(m.site.item, m.owner) }.uniq.first(MAX_RESULTS)
      end
      if t = type_at(offset)
        return map.descendants(t).flat_map { |d| map[d].sites.first(1) }.first(MAX_RESULTS)
      end
      [] of Semantics::Site
    end

    # Same-named, non-abstract defs in descendants of *owner*.
    private def method_implementations(item : Items::Item, owner : Semantics::TypeId) : Array(Semantics::Site)
      name = member_key(item)
      result = [] of Semantics::Site
      map.descendants(owner).each do |d|
        map[d].members[name]?.try &.each do |site|
          next unless site.item.kind.def?
          next if site.item.signature.try(&.is_abstract)
          result << site
        end
        break if result.size >= MAX_RESULTS
      end
      result
    end

    private def member_key(item : Items::Item) : String
      item.signature.try(&.receiver) ? "self.#{item.name}" : item.name
    end

    # `def foo` under the cursor (on its name) with its owner type.
    def def_item_at(offset : UInt32) : {Items::Item, Semantics::TypeId}?
      ns = map.namespace_at(@state.id, offset)
      map[ns].each_member_site do |site|
        next unless site.file == @state.id
        next unless site.item.kind.def? || site.item.kind.macro?
        return {site.item, ns} if site.item.name_range.touches?(offset)
      end
      nil
    end

    # The type whose declaration name, or a constant naming it, is under the
    # cursor.
    private def type_at(offset : UInt32) : Semantics::TypeId?
      loc = @analysis.definition(offset).first? || return nil
      map.types.each do |t|
        next if t.kind.alias? || t.kind.type_def?
        return t.id if t.sites.any? { |s| s.file == loc.file && s.item.name_range == loc.range }
      end
      nil
    end

    # -- type definition ----------------------------------------------------------------

    MAX_TYPE_SITES = 10

    # Declarations of the type of the value under the cursor (a union: of
    # each member); on a constant naming a type, that type. Generic
    # arguments are not followed. Unknown types give nothing.
    # *library*: stdlib/shard files (their reopenings are skipped).
    def type_definitions(offset : UInt32, library : FileId -> Bool) : Array(Semantics::Site)
      ids = [] of Semantics::TypeId
      if t = TypeInfo.new(@state, @bodies, @typing).type_at(offset)
        collect_type_ids(t, ids)
      elsif t = type_at(offset)
        ids << t
      end
      ids.uniq.flat_map { |id| type_sites(id, library) }.first(MAX_TYPE_SITES)
    end

    private def collect_type_ids(t : Types::TyId, ids : Array(Semantics::TypeId)) : Nil
      table = @typing.table
      ty = table[t]
      case ty.kind
      when .named?     then ids << ty.def_id.not_nil!
      when .union?     then ty.args.each { |a| collect_type_ids(a, ids) }
      when .metaclass? then collect_type_ids(ty.args[0], ids)
      when .tuple?       then map.lookup_path("::Tuple").try { |id| ids << id }
      when .named_tuple? then map.lookup_path("::NamedTuple").try { |id| ids << id }
      when .proc?        then map.lookup_path("::Proc").try { |id| ids << id }
      end
    end

    # A type's declaration: its first site (where the program first sees
    # it), plus the first reopening in each workspace file. Stdlib/shard
    # reopenings (`String` in a dozen files) are left out.
    private def type_sites(id : Semantics::TypeId, library : FileId -> Bool) : Array(Semantics::Site)
      sites = map[id].sites
      first = sites.first? || return [] of Semantics::Site
      seen = Set{first.file}
      [first] + sites.select { |s| !library.call(s.file) && seen.add?(s.file) }
    end

    # -- outgoing calls -----------------------------------------------------------------

    # The def at *offset* (inside its body or on its name), as a call item.
    def call_item_at(offset : UInt32) : CallItem?
      ns = map.namespace_at(@state.id, offset)
      best = nil.as(Semantics::Site?)
      map[ns].each_member_site do |site|
        next unless site.file == @state.id && site.item.kind.def?
        next unless site.item.range.touches?(offset)
        best = site if best.nil? || site.item.range.size < best.item.range.size
      end
      best.try { |b| CallItem.new(b, ns) }
    end

    # Resolved calls in *item*'s body, grouped by target.
    def outgoing_calls(item : CallItem) : Array(OutgoingCall)
      return [] of OutgoingCall unless item.site.file == @state.id
      start = item.site.item.range.start + 1
      body, inf = @typing.infer_at(@state, @bodies, start) || return [] of OutgoingCall
      return [] of OutgoingCall unless body.range == item.site.item.range
      by_target = {} of {FileId, UInt32} => OutgoingCall
      body.exprs.each do |e|
        next unless e.kind.call? && (nr = e.name_range)
        res = inf.resolutions[e.id]? || next
        res.matches.each do |m|
          key = {m.site.file, m.site.item.range.start}
          entry = by_target[key] ||= OutgoingCall.new(CallItem.new(m.site, m.owner), [] of TextRange)
          entry.ranges << nr unless entry.ranges.includes?(nr)
        end
      end
      by_target.values
    end
  end
end
