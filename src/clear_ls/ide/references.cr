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

  # An instance or class variable of one type (the nearest ancestor that
  # declares or assigns it, like the compiler's lookup).
  class IvarTarget < RefTarget
    getter owner_name : String
    getter? class_var : Bool

    def initialize(name, @owner_name, @class_var)
      super(name)
    end
  end

  # Everything one accessor macro argument generates (`property name`):
  # its getters (`name`, `name?`), setter (`name=`) and ivar (`@name`),
  # searched and renamed as one symbol. *base* is the written name
  # (`name`), *name_range* its token in the declaration.
  class AccessorTarget < RefTarget
    getter methods : Array(Semantics::Site)
    getter ivar : IvarTarget?
    getter decl_file : FileId
    getter name_range : TextRange
    # `record` fields: the generated `initialize`, whose named arguments
    # (`Point.new(x: 1)`) name the field.
    getter initializer : Semantics::Site?

    def initialize(name, @methods, @ivar, @decl_file, @name_range, @initializer = nil)
      super(name)
    end

    # `name` → `title`: each member's new name (`name?` → `title?`).
    def renamed(member : String, new_base : String) : String
      member.sub(name, new_base)
    end
  end

  # Too many candidate files for one search (`References#max_candidates`).
  class CandidateLimit < Exception
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
    # *describe*: `file:line` of a reference, for messages.
    # *checkpoint*: called between candidate files and bodies with what
    # was covered so far and the file about to be read; it may raise to
    # stop the search (cancellation, budget) and yield to other work.
    def initialize(@index : Workspace::Index, @context_for : Proc(FileId, Context?),
                   @describe : Proc(Reference, String) = ->(r : Reference) { "#{r.file.value}:#{r.range.start}" },
                   @checkpoint : Proc(String, FileId?, Nil) = ->(_p : String, _f : FileId?) { })
    end

    # Most candidate files searched per request (a common name in a big
    # program); over it the search fails clearly instead of running on.
    property max_candidates = 2000

    # Declarations that calls name: defs, macros, and C bindings (`fun`,
    # `$var`, lib struct/union fields; `Infer#lib_member_call`).
    def self.callable?(item : Items::Item) : Bool
      k = item.kind
      k.def? || k.macro? || k.fun? || k.c_var? || k.c_field?
    end

    def target_at(ctx : Context, offset : UInt32) : RefTarget?
      t = ivar_target(ctx, offset) || method_target(ctx, offset) || path_target(ctx, offset)
      accessor_target(ctx, offset, t) || t
    end

    # The accessor declaration whose name is at *offset*, or whose member
    # *t* is (a call of a generated getter/setter, or its `@ivar`).
    private def accessor_target(ctx : Context, offset : UInt32, t : RefTarget?) : AccessorTarget?
      map = ctx.typing.def_map
      seed = case t
             when MethodTarget
               t.sites.find { |s| s.item.origin.macro? && s.item.kind.def? }
             when IvarTarget
               owner = map.lookup_path("::" + t.owner_name)
               owner.try { |o| map[o].members[t.name]?.try &.find(&.item.origin.macro?) }
             else
               # On the name in `property name = "x"` (a class-body local
               # for the body lowering, nothing for the targets above).
               ns = map.namespace_at(ctx.state.id, offset)
               found = nil.as(Semantics::Site?)
               map[ns].each_member_site do |s|
                 if s.file == ctx.state.id && s.item.origin.macro? && s.item.name_range.touches?(offset) &&
                    (s.item.kind.def? || s.item.kind.instance_var? || s.item.kind.class_var?)
                   found = s
                 end
               end
               found
             end
      seed = seed || return nil
      accessor_group(map, seed)
    end

    # Members generated from the same macro argument as *seed* (same file
    # and name token), in the type that declares it.
    private def accessor_group(map : Semantics::DefMap, seed : Semantics::Site) : AccessorTarget?
      owner = map.namespace_at(seed.file, seed.item.range.start)
      methods = [] of Semantics::Site
      ivar = nil.as(IvarTarget?)
      map[owner].each_member_site do |s|
        next unless s.file == seed.file && s.item.origin.macro? && s.item.name_range == seed.item.name_range
        if s.item.kind.def?
          methods << s
        elsif s.item.kind.instance_var? || s.item.kind.class_var?
          ivar = IvarTarget.new(s.item.name, map[owner].full_name, s.item.kind.class_var?)
        end
      end
      return nil if methods.empty?
      # `record` fields and accessors: the written name is the getter's
      # name without `?`, or the setter's without `=`.
      base = methods.map { |m| m.item.name.rchop('=').rchop('?') }.min_by(&.size)
      # Generated members share the name token: `site_key` alone would
      # merge the getter and the setter.
      init = nil.as(Semantics::Site?)
      if map[owner].sites.any? { |s| s.item.origin.macro? && s.item.kind.struct? }
        init = map[owner].members["initialize"]?.try &.find { |s| s.file == seed.file && s.item.origin.macro? }
      end
      AccessorTarget.new(base, methods.uniq { |m| {site_key(m), m.item.name} }, ivar, seed.file, seed.item.name_range, init)
    end

    # References of *target* in every candidate file.
    def find(target : RefTarget, from : FileId) : Array(Reference)
      found = [] of Reference
      if target.is_a?(AccessorTarget)
        return accessor_refs(target, from)
      end
      word = case target
             when PathTarget then target.name.split("::").last
             when IvarTarget then target.name.lchop('@').lchop('@')
             else                 References.setter?(target.name) ? target.name.rchop('=') : target.name
             end
      candidates = @index.files_with_word(word)
      # Ivars: files of the requesting file's program.
      candidates.select! { |f| @index.visible_files(from).includes?(f) } if target.is_a?(IvarTarget)
      target_files = target_sites(target).map(&.file).to_set
      if candidates.size > @max_candidates
        raise CandidateLimit.new("`#{word}` appears in #{candidates.size} files (limit #{@max_candidates}); search not run")
      end
      candidates.each_with_index do |file, i|
        @checkpoint.call("#{i} of #{candidates.size} candidate files searched", file)
        # The file must see the target's declaration (one of them).
        next unless target.is_a?(IvarTarget) || @index.visible_files(file).any? { |f| target_files.includes?(f) }
        ctx = @context_for.call(file) || next
        case target
        when MethodTarget then method_refs(ctx, target, found)
        when PathTarget   then path_refs(ctx, target, found)
        when IvarTarget   then ivar_refs(ctx, target, found)
        end
        break if found.size >= MAX_RESULTS
      end
      declarations(target, found)
      dedupe(found)
    end

    # Uses of every member, then the declaration's name token once.
    # Member methods are searched with their override families (a `def
    # name` in a subclass overrides the generated getter).
    private def accessor_refs(target : AccessorTarget, from : FileId) : Array(Reference)
      found = [] of Reference
      target.methods.group_by(&.item.name).each do |name, sites|
        found.concat(find(MethodTarget.new(name, sites, Semantics::DefMap::PROGRAM), from))
      end
      target.ivar.try { |iv| found.concat(find(iv, from)) }
      target.initializer.try { |init| found.concat(named_arg_refs(target, init, from)) }
      # Generated members all point at the declaration's name; report it
      # once, as the declaration.
      found.reject! { |r| r.file == target.decl_file && r.range == target.name_range }
      found << Reference.new(target.decl_file, target.name_range, true, true)
      dedupe(found)
    end

    # `Point.new(x: 1)` for record field `x`: named arguments of calls
    # resolving to the record's `initialize` (through `new`).
    private def named_arg_refs(target : AccessorTarget, init : Semantics::Site, from : FileId) : Array(Reference)
      found = [] of Reference
      key = site_key(init)
      @index.files_with_word(target.name).each do |file|
        next unless @index.visible_files(file).includes?(target.decl_file)
        ctx = @context_for.call(file) || next
        word = /(?<![\w@$])#{Regex.escape(target.name)}(?=\s*:[^:])/
        seen = Set(TextRange).new
        ctx.state.text.scan(word) do |m|
          off = m.byte_begin(0).to_u32
          body = ctx.bodies.at(off) || next
          next unless seen.add?(body.range)
          _, calls = ctx.typing.call_facts(ctx.state, ctx.bodies, off) || next
          calls.each_value do |cs|
            cs.each do |c|
              next unless c.targets.includes?(key) || c.init_targets.includes?(key)
              c.named_args.each { |(n, r)| found << Reference.new(file, r, true, false) if n == target.name }
            end
          end
        end
      end
      found
    end

    # -- rename -----------------------------------------------------------------------

    record RenamePlan, edits : Array(Reference)?, error : String?, range : TextRange?

    METHOD_NAME = /\A[a-z_][A-Za-z0-9_]*[?!=]?\z/
    TYPE_NAME   = /\A[A-Z][A-Za-z0-9_]*\z/
    IVAR_NAME   = /\A@@?[a-z_][A-Za-z0-9_]*\z/

    # Workspace rename of the symbol at *offset*: every exact reference,
    # or a reason to refuse. Refuses when identity is not certain (any
    # possible reference), when a declaration is generated (macro or
    # compiler) or outside the workspace (stdlib, shards), and for
    # operators. *new_name* nil only checks (prepareRename). Without
    # *search* only the static checks run (no reference search; the
    # range is the token under the cursor): prepareRename must be fast,
    # and `rename` repeats every check with the search.
    def rename_plan(ctx : Context, offset : UInt32, new_name : String?, search = true) : RenamePlan
      target = target_at(ctx, offset) || return refuse("nothing to rename here")
      return accessor_rename(ctx, target, offset, new_name, search) if target.is_a?(AccessorTarget)
      sites = target_sites(target)
      case target
      when MethodTarget
        return refuse("operators can't be renamed") unless target.name.matches?(METHOD_NAME)
        return refuse("`#{target.name}` is defined by a macro or the compiler") if sites.any? { |s| !s.item.origin.source? }
        if new_name && !new_name.matches?(METHOD_NAME)
          return refuse("#{new_name.inspect} is not a valid method name")
        end
      when PathTarget
        if sites.any? { |s| !s.item.origin.source? }
          return refuse("`#{target.full_name}` is defined by a macro or the compiler")
        end
        if new_name && !new_name.matches?(TYPE_NAME)
          return refuse("#{new_name.inspect} is not a valid type or constant name")
        end
      when IvarTarget
        if new_name && (!new_name.matches?(IVAR_NAME) || new_name.starts_with?("@@") != target.class_var?)
          return refuse("#{new_name.inspect} is not a valid #{target.class_var? ? "class" : "instance"} variable name")
        end
      end
      if sites.any? { |s| @index.library_file?(s.file) }
        return refuse("`#{target.name}` is declared outside the workspace")
      end
      if target.is_a?(MethodTarget)
        # Overrides and implementations are one virtual method: renaming
        # one alone would break the others (an abstract def left
        # unimplemented, an override that no longer overrides).
        target = family(ctx, target)
        sites = target.sites
        return refuse("`#{target.name}` is defined by a macro or the compiler") if sites.any? { |s| !s.item.origin.source? }
        return refuse("`#{target.name}` overrides a method declared outside the workspace") if sites.any? { |s| @index.library_file?(s.file) }
      end
      if target.is_a?(IvarTarget) && (gen = ivar_generated?(ctx, target))
        return refuse(gen)
      end
      unless search
        r = cursor_range(ctx, target, offset) || return refuse("nothing to rename here")
        return RenamePlan.new(nil, nil, r)
      end
      refs = find(target, ctx.state.id)
      unsure = refs.reject(&.exact)
      unless unsure.empty?
        where = unsure.first(3).map { |r| @describe.call(r) }.join(", ")
        more = unsure.size > 3 ? " and #{unsure.size - 3} more" : ""
        return refuse("#{unsure.size} use(s) of `#{target.name}` can't be confirmed (unknown receiver type): #{where}#{more}")
      end
      if refs.any? { |r| @index.library_file?(r.file) }
        return refuse("`#{target.name}` is used outside the workspace")
      end
      range = refs.find { |r| r.file == ctx.state.id && r.range.touches?(offset) }.try(&.range)
      RenamePlan.new(refs, nil, range)
    end

    ACCESSOR_NAME = /\A[a-z_][A-Za-z0-9_]*\z/

    # `name=` (not `==`, `[]=`, `<=`).
    def self.setter?(name : String) : Bool
      name.ends_with?('=') && name.rchop('=').matches?(ACCESSOR_NAME)
    end

    # Renames every member: `name` → `title` gives `title`, `title?`,
    # `title=`, `@title` and the declaration. Each edit's text depends on
    # what it covers (`RenamePlan#texts`).
    private def accessor_rename(ctx : Context, target : AccessorTarget, offset : UInt32, new_name : String?, search : Bool) : RenamePlan
      if new_name && !new_name.matches?(ACCESSOR_NAME)
        return refuse("#{new_name.inspect} is not a valid accessor name (write it without `?`, `=` or `@`)")
      end
      if @index.library_file?(target.decl_file)
        return refuse("`#{target.name}` is declared outside the workspace")
      end
      unless search
        r = cursor_range(ctx, target, offset) || return refuse("nothing to rename here")
        return RenamePlan.new(nil, nil, r)
      end
      refs = find(target, ctx.state.id)
      unsure = refs.reject(&.exact)
      unless unsure.empty?
        where = unsure.first(3).map { |r| @describe.call(r) }.join(", ")
        more = unsure.size > 3 ? " and #{unsure.size - 3} more" : ""
        return refuse("#{unsure.size} use(s) of `#{target.name}` can't be confirmed (unknown receiver type): #{where}#{more}")
      end
      if refs.any? { |r| @index.library_file?(r.file) }
        return refuse("`#{target.name}` is used outside the workspace")
      end
      # Each reference covers the base name only (`name` in `x.name=`,
      # `@name`'s `name`, `name` in `name?`): one replacement text.
      edits = refs.compact_map { |r| base_range(r, target.name) }
      range = edits.find { |r| r.file == ctx.state.id && r.range.touches?(offset) }.try(&.range)
      RenamePlan.new(edits, nil, range)
    end

    # The part of *r* that spells *base*: references cover `name`,
    # `name?`, `name=`, `@name` or `.name`.
    private def base_range(r : Reference, base : String) : Reference?
      text = @context_for.call(r.file).try(&.state.text) || return nil
      t = text.byte_slice(r.range.start, r.range.size)
      i = t.byte_index(base) || return nil
      start = r.range.start + i.to_u32
      r.copy_with(range: TextRange.new(start, start + base.bytesize.to_u32))
    end

    # Every def with the same name in the targets' hierarchy: from the
    # topmost ancestor that declares it, all descendants that do.
    def family(ctx : Context, target : MethodTarget) : MethodTarget
      map = ctx.typing.def_map
      key = ->(s : Semantics::Site) { s.item.signature.try(&.receiver) ? "self.#{s.item.name}" : s.item.name }
      result = target.sites.dup
      target.sites.each do |site|
        k = key.call(site)
        owner = map.namespace_at(site.file, site.item.range.start)
        tops = map.ancestors(owner).select { |a| map[a].members[k]?.try &.any?(&.item.kind.def?) }
        tops = [owner] if tops.empty?
        tops.each do |top|
          ([top] + map.descendants(top)).each do |t|
            map[t].members[k]?.try &.each { |s| result << s if s.item.kind.def? }
          end
        end
      end
      MethodTarget.new(target.name, result.uniq { |s| site_key(s) }, target.owner)
    end

    # A def's name under the cursor (takes precedence over the class-body
    # "locals" that accessor macro arguments lower to).
    def def_name_at?(ctx : Context, offset : UInt32) : Bool
      map = ctx.typing.def_map
      ns = map.namespace_at(ctx.state.id, offset)
      map[ns].each_member_site do |site|
        next unless site.file == ctx.state.id && References.callable?(site.item)
        return true if site.item.name_range.touches?(offset)
      end
      false
    end

    # The name token under the cursor: the identifier/constant segment or
    # ivar, for the static prepareRename answer.
    private def cursor_range(ctx : Context, target : RefTarget, offset : UInt32) : TextRange?
      if target.is_a?(AccessorTarget)
        node = ctx.state.tree.root.descendant(offset, offset, named: true) || return nil
        i = node.text.byte_index(target.name) || return nil
        start = node.start_byte + i.to_u32
        return TextRange.new(start, start + target.name.bytesize.to_u32)
      end
      if target.is_a?(PathTarget)
        hit = Analysis.new(ctx.state, @index, ctx.typing.def_map).resolve_path_at(offset).first?
        return hit.try(&.[:range])
      end
      node = ctx.state.tree.root.descendant(offset, offset, named: true) || return nil
      return node.range if node.text == target.name
      # `.foo` method token of an implicit-object call, `foo=`, `foo?`.
      t = node.text
      i = t.index(target.name) || return nil
      TextRange.new(node.start_byte + i.to_u32, node.start_byte + (i + target.name.bytesize).to_u32)
    end

    private def refuse(msg : String) : RenamePlan
      RenamePlan.new(nil, msg, nil)
    end

    # Ivars of an accessor macro (`property x`) are renamed by renaming
    # the accessor; refuse here rather than leave `x` behind.
    private def ivar_generated?(ctx : Context, target : IvarTarget) : String?
      map = ctx.typing.def_map
      owner = map.lookup_path("::" + target.owner_name) || return nil
      sites = map[owner].members[target.name]? || return nil
      return nil unless sites.any? { |s| s.item.origin.macro? || s.item.origin.compiler? }
      "`#{target.name}` comes from an accessor macro; rename the accessor instead"
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
        next unless References.callable?(site.item)
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

    private def ivar_target(ctx : Context, offset : UInt32) : IvarTarget?
      node = ctx.state.tree.root.descendant(offset, offset, named: true) || return nil
      return nil unless node.kind.instance_var? || node.kind.class_var?
      owner = ivar_owner(ctx, node.text, node.kind.class_var?, offset) || return nil
      IvarTarget.new(node.text, ctx.typing.def_map[owner].full_name, node.kind.class_var?)
    end

    # The type whose `@x` this is: the nearest ancestor of the enclosing
    # namespace with an item for it (else the namespace itself).
    private def ivar_owner(ctx : Context, name : String, cvar : Bool, offset : UInt32) : Semantics::TypeId?
      map = ctx.typing.def_map
      ns = map.namespace_at(ctx.state.id, offset)
      return nil if ns == Semantics::DefMap::PROGRAM
      kind = cvar ? Items::ItemKind::ClassVar : Items::ItemKind::InstanceVar
      map.ancestors(ns).find { |a| map[a].members[name]?.try &.any?(&.item.kind.==(kind)) } || ns
    end

    # `@x` tokens in the file whose owner is the target's type. Ivars of
    # the type's own declarations are in its files; subtypes may use
    # inherited ivars anywhere.
    private def ivar_refs(ctx : Context, target : IvarTarget, found : Array(Reference)) : Nil
      ctx.state.tree.root.walk do |node|
        next !node.kind.comment? unless node.kind.instance_var? || node.kind.class_var?
        next false unless node.text == target.name && node.kind.class_var? == target.class_var?
        owner = ivar_owner(ctx, target.name, target.class_var?, node.start_byte) || next false
        if ctx.typing.def_map[owner].full_name == target.owner_name
          found << Reference.new(ctx.state.id, node.range, true, ivar_declaration?(node))
        end
        false
      end
    end

    # `@x : T`, `@x = v` at type level, `getter`-free: a declaration site.
    private def ivar_declaration?(node : Syntax::Node) : Bool
      parent = node.parent || return false
      parent.kind.type_declaration? || parent.kind.param?
    end

    # -- method uses --------------------------------------------------------------------

    private def method_refs(ctx : Context, target : MethodTarget, found : Array(Reference)) : Nil
      keys = target.sites.map { |s| site_key(s) }.to_set
      text = ctx.state.text
      # Setters are spelled `x.name = v` / `x.name += v`: find the base
      # word (call facts then pick the `name=` calls).
      spelled = References.setter?(target.name) ? target.name.rchop('=') : target.name
      word = /(?<![\w@$])#{Regex.escape(spelled)}(?![\w?!])/
      # By range: a file body starts where a leading def does.
      seen_bodies = Set(TextRange).new
      text.scan(word) do |m|
        off = m.byte_begin(0).to_u32
        body = ctx.bodies.at(off) || next
        next unless seen_bodies.add?(body.range)
        @checkpoint.call("", nil) if seen_bodies.size > 1
        _, calls = ctx.typing.call_facts(ctx.state, ctx.bodies, off) || next
        # A C field or `$var` is both read (`s.x`) and written (`s.x = v`).
        names = [target.name]
        names << "#{target.name}=" if target.sites.any? { |st| st.item.kind.c_field? || st.item.kind.c_var? }
        names.flat_map { |n| calls[n]? || [] of Typing::CallFact }.each do |c|
          if c.resolved && !c.targets.empty?
            next unless c.targets.any? { |t| keys.includes?(t) }
            exact = c.kind.unique? || c.kind.multiple_runtime_targets? || c.targets.all? { |t| keys.includes?(t) }
            found << Reference.new(ctx.state.id, c.name_range, exact, false)
          elsif !c.resolved || c.kind.name_only? || c.kind.unresolved?
            # Unknown receiver or no fitting overload: same name, unknown
            # identity. A receiverless call that resolved to nothing in a
            # typed scope is not a use.
            possible = !c.resolved || c.kind.name_only? || c.has_receiver
            found << Reference.new(ctx.state.id, c.name_range, false, false) if possible
          end
        end
      end
    end

    private def site_key(s : Semantics::Site) : {Int32, UInt32}
      # Same key as `Typing::CallFact#targets`.
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
