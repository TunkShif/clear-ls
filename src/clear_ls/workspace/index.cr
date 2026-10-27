require "./project"
require "../base/memory"
require "../vfs"
require "../semantics/def_map"
require "../semantics/def_id"
require "./compiler_facts"

module ClearLS::Workspace
  # Item trees for every indexed file, and `DefMap`s over program views.
  #
  # Files come from two sources:
  # - the require closure of the prelude and of every workspace file
  #   (stdlib, shards in `lib/`, required project files);
  # - all `.cr` files under the project root (not in nested projects).
  #
  # A *view* is what one program can see, like the compiler would compile
  # it: the prelude plus the require closure of its root files. The
  # project view's roots are `Project#program_roots` (shard targets, else
  # `src/`); a workspace file outside that closure (a script, a spec) gets
  # a view of its own, so it sees what it requires but nothing else, and
  # the project does not see it. `#def_map` is the project view's map.
  #
  # Only item trees are kept for closed files; syntax trees are dropped
  # after lowering. Open buffers come from the VFS and override disk.
  #
  # DefMaps are rebuilt from item trees when a file of their view changes
  # its item fingerprint. Edits inside method bodies keep the fingerprint,
  # so they do not rebuild them (`#rebuilds` counts rebuilds for tests).
  class Index
    record Entry, path : String, items : Items::ItemTree, fingerprint : UInt64, requires : Array(String)

    # Identifier-like words of each workspace file (not the stdlib or
    # shards), for narrowing reference searches: a file can only refer to
    # `foo` if it contains the word. Hashes keep it small; a collision
    # only adds a candidate file. `StableHash`, so the sets can be cached.
    @words = {} of FileId => Set(UInt64)

    # A program view: root files and the DefMap over their closure.
    class View
      getter roots : Array(FileId)
      property def_map : Semantics::DefMap? = nil
      property files : Set(FileId)? = nil

      def initialize(@roots)
      end
    end

    getter project : Project
    getter rebuilds = 0
    @entries = {} of FileId => Entry
    @project_view = View.new([] of FileId)
    # Views of workspace files outside the project's closure, by file.
    @file_views = {} of FileId => View
    @facts = CompilerFacts.new
    # Members added from compiler facts in the last built DefMap.
    getter fact_members = 0

    getter facts

    # Replaces the compiler facts; rebuilds the DefMaps when they changed.
    def facts=(facts : CompilerFacts) : Nil
      return if facts == @facts
      @facts = facts
      invalidate_maps
    end

    def initialize(@project : Project, @vfs : VFS)
    end

    # The project view's DefMap.
    def def_map : Semantics::DefMap
      map_of(@project_view)
    end

    # DefMap of the view that *file* belongs to.
    def def_map_for(file : FileId) : Semantics::DefMap
      map_of(view_for(file))
    end

    # The project view when *file* is in its closure (or not indexed),
    # else the file's own view.
    def view_for(file : FileId) : View
      return @project_view if files_of(@project_view).includes?(file)
      entry = @entries[file]? || return @project_view
      # A stdlib or shard file outside the project's closure (opened by
      # go-to-definition, or required only by specs): the union view over
      # everything indexed, since such a file is usually part of a larger
      # library program (`spec/context.cr` needs `spec/example.cr`).
      return library_view if library_path?(entry.path)
      if (group = spec_group(entry))
        return spec_view(group)
      end
      # A support file of the specs (`spec/test_project/...`, required by
      # the helper): the spec program it belongs to.
      if (view = spec_view_containing(file, entry))
        return view
      end
      @file_views[file] ||= begin
        # Inside a nested project (its own `shard.yml` below the root):
        # that project's program, else the file alone.
        sub = Project.find_root(entry.path)
        if sub && sub != @project.root && (view = nested_view(sub, file))
          view
        else
          View.new([file])
        end
      end
    end

    @nested_views = {} of String => View
    @library_view : View? = nil
    # Spec programs by (project root, first required file).
    @spec_views = {} of {String, String} => View

    # `crystal spec` compiles every `spec/**/*_spec.cr` of a project as one
    # program. Spec files whose first `require` is the same file (the
    # spec helper) are grouped into one view the same way: they are
    # written to compile together, and one view means one DefMap and one
    # summary cache however many of them are open.
    private def spec_group(entry : Entry) : {String, String}?
      return nil unless entry.path.ends_with?("_spec.cr")
      root = Project.find_root(entry.path) || @project.root
      spec_dir = File.join(root, "spec") + "/"
      return nil unless entry.path.starts_with?(spec_dir)
      first = entry.requires.first?
      return nil unless first
      {root, top_helper(first, spec_dir)}
    end

    # Per-directory helpers usually chain up (`spec/a/b/spec_helper.cr`
    # requires `../spec_helper`): follow first requires while they stay
    # in `spec/` and are named like the helper, so every spec of the
    # project lands in one group.
    private def top_helper(helper : String, spec_dir : String) : String
      seen = Set{helper}
      name = File.basename(helper)
      cur = helper
      while (e = @entries[id_of(cur)]?) && (nxt = e.requires.first?)
        break unless nxt.starts_with?(spec_dir) && File.basename(nxt) == name && seen.add?(nxt)
        cur = nxt
      end
      cur
    end

    private def spec_view_containing(file : FileId, entry : Entry) : View?
      return @support_views[file] if @support_views.has_key?(file)
      @support_views[file] = spec_view_containing_uncached(file, entry)
    end

    private def spec_view_containing_uncached(file : FileId, entry : Entry) : View?
      root = Project.find_root(entry.path) || @project.root
      return nil unless entry.path.starts_with?(File.join(root, "spec") + "/")
      # Build the views of this project's spec groups (cheap: one per
      # helper), then pick the one whose closure has the file.
      helper_groups(root).each do |g|
        v = spec_view(g)
        return v if files_of(v).includes?(file)
      end
      nil
    end

    @helper_groups = {} of String => Array({String, String})
    # File → its spec program, for support files (cleared with the views).
    @support_views = {} of FileId => View?

    private def helper_groups(root : String) : Array({String, String})
      @helper_groups[root] ||= helper_groups_uncached(root)
    end

    private def helper_groups_uncached(root : String) : Array({String, String})
      spec_dir = File.join(root, "spec") + "/"
      groups = Set({String, String}).new
      @entries.each_value do |e|
        next unless e.path.ends_with?("_spec.cr") && e.path.starts_with?(spec_dir)
        g = spec_group(e)
        groups << g if g
      end
      groups.to_a
    end

    private def spec_view(group : {String, String}) : View
      @spec_views[group] ||= begin
        root, helper = group
        spec_dir = File.join(root, "spec") + "/"
        files = [] of FileId
        @entries.each do |id, e|
          next unless e.path.ends_with?("_spec.cr") && e.path.starts_with?(spec_dir)
          first = e.requires.first? || next
          files << id if top_helper(first, spec_dir) == helper && Project.find_root(e.path) == root
        end
        View.new(files.sort_by(&.value))
      end
    end

    # Every indexed file (what the old single DefMap covered).
    private def library_view : View
      @library_view ||= begin
        v = View.new([] of FileId)
        v.files = @entries.keys.to_set
        v
      end
    end

    # The program view of the nested project at *root*, when *file* is in
    # its closure. Its files are indexed on first use.
    private def nested_view(root : String, file : FileId) : View?
      view = @nested_views[root] ||= begin
        nested = Project.new(root, [] of String, nil, nil, @project.target_triple)
        paths = nested.program_roots
        load_missing(paths)
        View.new(paths.map { |p| id_of(p) })
      end
      files_of(view).includes?(file) ? view : nil
    end

    # In the stdlib or a shard (a `CRYSTAL_PATH` entry).
    def library_file?(file : FileId) : Bool
      @entries[file]?.try { |e| library_path?(e.path) } || false
    end

    private def library_path?(path : String) : Bool
      @project.crystal_path.any? { |d| path.starts_with?(d.ends_with?('/') ? d : d + "/") }
    end

    # Files visible in *file*'s view.
    def visible_files(file : FileId) : Set(FileId)
      files_of(view_for(file))
    end

    private def map_of(view : View) : Semantics::DefMap
      view.def_map ||= begin
        @rebuilds += 1
        map = Semantics::DefMap.new(@project.flags)
        visible = files_of(view)
        @entries.each { |id, e| map.add_file(id, e.items) if visible.includes?(id) }
        unless @facts.empty?
          elapsed = Time.measure do
            @fact_members = @facts.apply(map, ->(path : String) { @vfs.id_for(VFS.uri_for(path)) }, ->saved_text(String), visible)
          end
          Log.debug { "applied compiler facts: #{@fact_members} members in #{elapsed.total_milliseconds.round(1)}ms" }
        end
        map
      end
    end

    # Prelude closure plus the view's roots' closure.
    private def files_of(view : View) : Set(FileId)
      view.files ||= begin
        roots = view.roots.empty? ? project_roots : view.roots
        @project.prelude.try { |p| roots = [id_of(p)] + roots }
        closure(roots)
      end
    end

    private def project_roots : Array(FileId)
      @project.program_roots.map { |p| id_of(p) }
    end

    private def closure(roots : Array(FileId)) : Set(FileId)
      seen = Set(FileId).new
      queue = roots.dup
      while id = queue.pop?
        next unless seen.add?(id)
        @entries[id]?.try &.requires.each { |r| queue << id_of(r) }
      end
      seen
    end

    private def id_of(path : String) : FileId
      @vfs.id_for(VFS.uri_for(path))
    end

    # Drops every DefMap and view closure (declarations or requires
    # changed somewhere).
    private def invalidate_maps : Nil
      @project_view.def_map = nil
      @project_view.files = nil
      @file_views.clear
      @nested_views.each_value { |v| v.def_map = nil; v.files = nil }
      @library_view = nil
      @spec_views.clear
      @helper_groups.clear
      @support_views.clear
    end

    def entry?(file : FileId) : Entry?
      @entries[file]?
    end

    def size : Int32
      @entries.size
    end

    def each_entry(& : FileId, Entry ->) : Nil
      @entries.each { |id, e| yield id, e }
    end

    # Where the last `#load` spent its time (wall clock; parse is the
    # parallel batches, the rest runs on the calling fiber).
    record LoadStats, rounds : Int32 = 0, walk : Time::Span = Time::Span.zero,
      parse : Time::Span = Time::Span.zero, resolve : Time::Span = Time::Span.zero,
      words : Time::Span = Time::Span.zero, trim : Time::Span = Time::Span.zero,
      total : Time::Span = Time::Span.zero

    getter load_stats = LoadStats.new

    # Indexes the prelude closure and workspace files from disk, then their
    # require closure. Parses in parallel with *workers* threads.
    def load(workers : Int32 = default_workers) : Nil
      start = Time.instant
      rounds = 0
      parse = resolve = words = Time::Span.zero
      roots = [] of String
      walk = Time.measure { roots = @project.source_files }
      @project.prelude.try { |p| roots.unshift(p) }
      pending = roots.to_set
      seen = Set(String).new
      until pending.empty?
        rounds += 1
        batch = pending.to_a.reject { |p| seen.includes?(p) }
        seen.concat(batch)
        pending = Set(String).new
        t = Time.instant
        parsed = parse_batch(batch, workers)
        parse += t.elapsed
        parsed.each do |path, items|
          next unless items
          id = @vfs.id_for(VFS.uri_for(path))
          # An open buffer is authoritative; keep its entry.
          next if @entries[id]? && @vfs.open?(VFS.uri_for(path))
          t = Time.instant
          entry = make_entry(path, items)
          resolve += t.elapsed
          @entries[id] = entry
          t = Time.instant
          read_words(id, path)
          words += t.elapsed
          entry.requires.each { |r| pending << r unless seen.includes?(r) }
        end
      end
      invalidate_maps
      trim = Time.measure { ClearLS::Memory.trim } # parse workers' freed trees (see Memory)
      @load_stats = LoadStats.new(rounds, walk, parse, resolve, words, trim, start.elapsed)
      Log.info { "indexed #{@entries.size} files" }
    end

    # Re-lowers an open/changed file from its current VFS state. Returns true
    # when declarations changed (DefMap invalidated).
    def update(state : FileState) : Bool
      path = VFS.path_for(state.uri) || state.uri
      @words[state.id] = Index.words(state.text) unless library_path?(path)
      items = Items::Lower.lower(state.tree)
      entry = make_entry(path, items)
      old = @entries[state.id]?
      changed = old.nil? || old.fingerprint != entry.fingerprint
      if changed
        @entries[state.id] = entry
        invalidate_maps
        load_missing(entry.requires)
      else
        # Same declarations, possibly moved by a body edit: the DefMap's
        # sites share the old items, so move those (no rebuild).
        old = old.not_nil!
        old.items.move_to(items)
        @entries[state.id] = Entry.new(path, old.items, old.fingerprint, entry.requires)
        each_map(&.positions_changed)
      end
      changed
    end

    # Removes a file (deleted from disk).
    def remove(file : FileId) : Nil
      @words.delete(file)
      invalidate_maps if @entries.delete(file)
    end

    WORD = /[A-Za-z_][A-Za-z0-9_]*[?!=]?/

    def self.words(text : String) : Set(UInt64)
      set = Set(UInt64).new
      text.scrub.scan(WORD) { |m| set << StableHash.hash(m[0]) }
      set
    end

    # Workspace files whose text contains *word* (open buffers as edited).
    def files_with_word(word : String) : Array(FileId)
      h = StableHash.hash(word)
      found = [] of FileId
      @words.each { |id, set| found << id if set.includes?(h) }
      found
    end

    # The `DefId` of a site, if its item is still in the index.
    def def_id(site : Semantics::Site) : Semantics::DefId?
      tree = @entries[site.file]?.try(&.items) || return nil
      Semantics::DefId.of(site.file, tree, site.item)
    end

    # The item a `DefId` names, if the file still has it.
    def item(id : Semantics::DefId) : Items::Item?
      @entries[id.file]?.try { |e| id.item_in(e.items) }
    end

    # Views with a built DefMap, by kind (debugging / probes).
    def view_stats : Hash(String, Int32)
      h = Hash(String, Int32).new(0)
      h["project"] += 1 if @project_view.def_map
      @file_views.each_value { |v| h["file"] += 1 if v.def_map }
      @nested_views.each_value { |v| h["nested"] += 1 if v.def_map }
      @spec_views.each_value { |v| h["spec"] += 1 if v.def_map }
      h["library"] += 1 if @library_view.try(&.def_map)
      h
    end

    # True while *map* is the current DefMap of some view.
    def live_map?(map : Semantics::DefMap) : Bool
      each_map { |m| return true if m.same?(map) }
      false
    end

    private def each_map(& : Semantics::DefMap ->) : Nil
      @project_view.def_map.try { |m| yield m }
      @file_views.each_value { |v| v.def_map.try { |m| yield m } }
      @nested_views.each_value { |v| v.def_map.try { |m| yield m } }
      @library_view.try(&.def_map).try { |m| yield m }
      @spec_views.each_value { |v| v.def_map.try { |m| yield m } }
    end

    # Text of a file as the compiler saw it, unless an open buffer differs
    # (then compiler locations may not match the indexed declarations).
    private def saved_text(path : String) : String?
      return nil unless File.file?(path)
      text = File.read(path)
      if (state = @vfs.file?(VFS.uri_for(path))) && state.overlay? && state.text != text
        return nil
      end
      text
    end

    # Indexes *paths* and, transitively, what they require.
    private def load_missing(paths : Array(String)) : Nil
      pending = paths
      until pending.empty?
        missing = pending.uniq.reject { |p| @entries.has_key?(@vfs.id_for(VFS.uri_for(p))) }
        return if missing.empty?
        pending = [] of String
        parse_batch(missing, 1).each do |path, items|
          next unless items
          entry = make_entry(path, items)
          id = @vfs.id_for(VFS.uri_for(path))
          @entries[id] = entry
          read_words(id, path)
          pending.concat(entry.requires)
        end
      end
    end

    private def read_words(id : FileId, path : String) : Nil
      return if library_path?(path)
      @words[id] = Index.words(File.read(path))
    rescue File::Error
    end

    private def make_entry(path : String, items : Items::ItemTree) : Entry
      reqs = [] of String
      items.requires.each do |r|
        next if Items::Cond.all(r.conditions, @project.flags) == false
        reqs.concat(@project.resolver.resolve(r.path, path))
      end
      Entry.new(path, items, items.fingerprint, reqs)
    end

    private def default_workers : Int32
      (System.cpu_count.to_i // 2).clamp(1, 8)
    end

    # Reads, parses and lowers files on a parallel execution context. Each
    # worker owns its parser; only item trees cross threads.
    private def parse_batch(paths : Array(String), workers : Int32) : Array({String, Items::ItemTree?})
      return [] of {String, Items::ItemTree?} if paths.empty?
      workers = Math.min(workers, paths.size)
      return parse_sequential(paths) if workers <= 1 || paths.size < 8

      queue = Channel(String).new(paths.size)
      paths.each { |p| queue.send(p) }
      queue.close
      results = Channel({String, Items::ItemTree?}).new(paths.size)
      ctx = Fiber::ExecutionContext::Parallel.new("clear-ls-index", workers)
      workers.times { ctx.spawn { parse_worker(queue, results) } }
      Array.new(paths.size) { results.receive }
    end

    # Kept in separate methods on purpose: Crystal closures capture
    # *method-level* variables, so a `parser = ...` local declared anywhere in
    # `parse_batch` would be one variable shared by every spawned block, i.e.
    # one TSParser used from many threads at once.
    private def parse_sequential(paths : Array(String)) : Array({String, Items::ItemTree?})
      parser = Syntax::Parser.new
      paths.map { |p| {p, lower_file(parser, p)} }
    end

    private def parse_worker(queue : Channel(String), results : Channel({String, Items::ItemTree?})) : Nil
      parser = Syntax::Parser.new
      while path = queue.receive?
        results.send({path, lower_file(parser, path)})
      end
    end

    private def lower_file(parser : Syntax::Parser, path : String) : Items::ItemTree?
      Items::Lower.lower(parser.parse(File.read(path)))
    rescue ex : IO::Error | File::Error
      Log.warn { "cannot read #{path}: #{ex.message}" }
      nil
    rescue ex
      Log.error(exception: ex) { "failed to index #{path}" }
      nil
    end
  end
end
