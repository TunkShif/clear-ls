require "./analysis"
require "./type_info"
require "./typing"

module ClearLS::IDE
  # One reference found by a workspace search.
  #
  # *exact*: the use resolves to the target (a call whose resolution
  # contains the def, a constant path that names the type). Possible
  # references share the name but their identity is unknown (ambiguous or
  # unresolved calls); they are reported separately and block rename.
  record Reference, file : FileId, range : TextRange, exact : Bool, declaration : Bool

  # What a references request is about.
  abstract class RefTarget
    getter name : String

    def initialize(@name)
    end
  end

  # A method family: every def that a call at the cursor could reach, or
  # the def under the cursor plus its overrides/implementations is NOT
  # included (only the same overload set). Identity is per site.
  class MethodTarget < RefTarget
    getter sites : Array(Semantics::Site)
    getter owner : Semantics::TypeId

    def initialize(name, @sites, @owner)
      super(name)
    end
  end

  # A type (all reopenings) or a constant.
  class PathTarget < RefTarget
    getter full_name : String
    getter sites : Array(Semantics::Site)
    getter? type : Bool

    def initialize(name, @full_name, @sites, @type)
      super(name)
    end
  end

  # Workspace references by identity (Phase 9).
  #
  # The target comes from the cursor: a def header or a call (methods), a
  # constant path (types and constants). Candidate files are the workspace
  # files whose word set contains the name and that can see the target's
  # declaration (same program view). Method uses are found by inferring
  # candidate bodies and keeping calls whose resolution contains one of
  # the target's sites; constant uses by resolving every constant path of
  # the file in its namespace. Declarations themselves (def names, type
  # names of every reopening) are references too.
  class References
    MAX_RESULTS = 2000

    record Context, state : FileState, bodies : Bodies, typing : Typing

    # *context_for*: analysis context of another file (open buffer or
    # disk), with the typing of its own program view.
    def initialize(@index : Workspace::Index, @context_for : Proc(FileId, Context?))
    end

    def target_at(ctx : Context, offset : UInt32) : RefTarget?
      method_target(ctx, offset) || path_target(ctx, offset)
    end

    # References of *target* in every candidate file.
    def find(target : RefTarget, from : FileId) : Array(Reference)
      found = [] of Reference
      word = target.is_a?(PathTarget) ? target.name.split("::").last : target.name
      visible_from = @index.visible_files(from)
      candidates = @index.files_with_word(word)
      target_files = target_sites(target).map(&.file).to_set
      candidates.each do |file|
        # The file must see the target's declaration (one of them).
        next unless @index.visible_files(file).any? { |f| target_files.includes?(f) }
        ctx = @context_for.call(file) || next
        case target
        when MethodTarget then method_refs(ctx, target, found)
        when PathTarget   then path_refs(ctx, target, found)
        end
        break if found.size >= MAX_RESULTS
      end
      declarations(target, found)
      dedupe(found)
    end

    private def target_sites(target : RefTarget) : Array(Semantics::Site)
      case target
      when MethodTarget then target.sites
      when PathTarget   then target.sites
      else                   [] of Semantics::Site
      end
    end

    # -- targets ----------------------------------------------------------------------

    private def method_target(ctx : Context, offset : UInt32) : MethodTarget?
      map = ctx.typing.def_map
      # On a def's name: that def.
      ns = map.namespace_at(ctx.state.id, offset)
      map[ns].each_member_site do |site|
        next unless site.file == ctx.state.id
        next unless site.item.kind.def? || site.item.kind.macro?
        if site.item.name_range.touches?(offset)
          return MethodTarget.new(site.item.name, [site], ns)
        end
      end
      # On a call: its viable targets (all of them: a reference to any is
      # a reference to the call).
      hit = TypeInfo.new(ctx.state, ctx.bodies, ctx.typing).call_at(offset) || return nil
      call, matches, _ = hit
      return nil if matches.empty?
      MethodTarget.new(call.name.not_nil!, matches.map(&.site).uniq, matches.first.owner)
    end

    private def path_target(ctx : Context, offset : UInt32) : PathTarget?
      analysis = Analysis.new(ctx.state, @index, ctx.typing.def_map)
      hit = analysis.resolve_path_at(offset).first? || return nil
      sites = hit[:sites]
      return nil if sites.empty?
      type = sites.any? { |s| s.item.kind.namespace? || s.item.kind.alias? || s.item.kind.type_def? }
      PathTarget.new(hit[:full_name].split("::").last, hit[:full_name], sites, type)
    end

    # -- method uses --------------------------------------------------------------------

    private def method_refs(ctx : Context, target : MethodTarget, found : Array(Reference)) : Nil
      keys = target.sites.map { |s| site_key(s) }.to_set
      text = ctx.state.text
      word = /(?<![\w@$])#{Regex.escape(target.name)}(?![\w?!])/
      seen_bodies = Set(UInt32).new
      text.scan(word) do |m|
        off = m.byte_begin(0).to_u32
        body = ctx.bodies.at(off) || next
        next unless seen_bodies.add?(body.range.start)
        _, inf = ctx.typing.infer_at(ctx.state, ctx.bodies, off) || next
        body.exprs.each do |e|
          next unless e.kind.call? && e.name == target.name && (nr = e.name_range)
          res = inf.resolutions[e.id]?
          if res && !res.candidates.empty?
            hit = res.matches.any? { |mm| keys.includes?(site_key(mm.site)) }
            next unless hit
            exact = res.kind.unique? || res.kind.multiple_runtime_targets? || res.matches.all? { |mm| keys.includes?(site_key(mm.site)) }
            found << Reference.new(ctx.state.id, nr, exact, false)
          elsif res.nil? || res.kind.name_only? || res.kind.unresolved?
            # Unknown receiver or no fitting overload: same name, unknown
            # identity.
            found << Reference.new(ctx.state.id, nr, false, false) if possible_call?(e, res)
          end
        end
      end
    end

    # A call with an unknown receiver (or a name-only resolution) may be a
    # use; a receiverless call that resolved to nothing in a typed scope
    # is not.
    private def possible_call?(e : HIR::Expr, res : Types::CallResolution?) : Bool
      return true if res.nil?
      res.kind.name_only? || !e.receiver.nil?
    end

    private def site_key(s : Semantics::Site) : {Int32, UInt32}
      {s.file.value.to_i32, s.item.name_range.start}
    end

    # -- constant uses ------------------------------------------------------------------

    private def path_refs(ctx : Context, target : PathTarget, found : Array(Reference)) : Nil
      analysis = Analysis.new(ctx.state, @index, ctx.typing.def_map)
      keys = target.sites.map { |s| site_key(s) }.to_set
      last = target.name
      ctx.state.tree.root.walk do |node|
        next !node.kind.comment? unless node.kind.constant?
        text = node.text
        # Every segment equal to the target's name: resolve the prefix up
        # to it (the cursor lookup does exactly that).
        idx = 0
        while (i = text.byte_index(last, idx))
          stop = i + last.bytesize
          boundary = (i == 0 || text.byte_slice(i - 2, 2) == "::") && (stop == text.bytesize || text.byte_slice(stop, 2) == "::")
          if boundary
            hit = analysis.resolve_path_at(node.start_byte + i.to_u32).first?
            if hit && hit[:full_name] == target.full_name && hit[:sites].any? { |s| keys.includes?(site_key(s)) }
              r = TextRange.new(node.start_byte + i.to_u32, node.start_byte + stop.to_u32)
              found << Reference.new(ctx.state.id, r, true, declaration_name?(node))
            end
          end
          idx = stop
        end
        false
      end
    end

    private def declaration_name?(node : Syntax::Node) : Bool
      parent = node.parent || return false
      return parent.field(Syntax::Field::Lhs) == node if parent.kind.const_assign?
      return false unless parent.field(Syntax::Field::Name) == node
      parent.kind.class_def? || parent.kind.struct_def? || parent.kind.module_def? || parent.kind.enum_def? ||
        parent.kind.lib_def? || parent.kind.annotation_def? || parent.kind.alias_node?
    end

    # -- declarations ---------------------------------------------------------------------

    private def declarations(target : RefTarget, found : Array(Reference)) : Nil
      return unless target.is_a?(MethodTarget)
      target.sites.each do |s|
        next unless s.item.origin.source?
        found << Reference.new(s.file, s.item.name_range, true, true)
      end
    end

    private def dedupe(found : Array(Reference)) : Array(Reference)
      by = {} of {Int32, UInt32} => Reference
      found.each do |r|
        key = {r.file.value.to_i32, r.range.start}
        prev = by[key]?
        by[key] = r if prev.nil? || (r.exact && !prev.exact) || (r.declaration && !prev.declaration)
      end
      by.values.sort_by { |r| {r.file.value, r.range.start} }
    end
  end
end
