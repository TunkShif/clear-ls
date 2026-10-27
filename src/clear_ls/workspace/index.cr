require "./project"
require "../base/memory"
require "../vfs"
require "../semantics/def_map"
require "../semantics/def_id"
require "./compiler_facts"
require "../cache/store"
require "../cache/local"

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
    # Persistent item trees of the stdlib and shards, and of everything
    # else (nil: no cache). See design/persistent-cache.md.
    property store : Cache::Store? = nil
    property local : Cache::Local? = nil
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

    # Where the last `#load` spent its time (wall clock). `index` is the
    # work-queue phase: parse, lower, require resolution and word sets on
    # the workers, entries added on the calling fiber.
    record LoadStats, files : Int32 = 0, walk : Time::Span = Time::Span.zero,
      index : Time::Span = Time::Span.zero, trim : Time::Span = Time::Span.zero,
      total : Time::Span = Time::Span.zero

    getter load_stats = LoadStats.new

    # Which cache layer a file belongs to, and whether it came from it.
    enum Cached
      None
      GlobalHit
      GlobalMiss
      LocalHit
      LocalMiss
    end

    # What a worker produces for one file. `words` is nil for library files
    # (not searched for references). `meta` is set for cache misses (the
    # entry to record).
    record Loaded, path : String, entry : Entry?, words : Set(UInt64)?,
      cached : Cached = Cached::None, meta : Cache::FileMeta? = nil

    # Indexes the prelude closure and workspace files from disk, then their
    # require closure, on *workers* threads. A shared work queue: each
    # file's resolved requires are queued as soon as it is done, so workers
    # never wait for a whole round.
    def load(workers : Int32 = default_workers) : Nil
      start = Time.instant
      roots = [] of String
      walk = Time.measure { roots = @project.source_files }
      @project.prelude.try { |p| roots.unshift(p) }
      t = Time.instant
      count = 0
      index_files(roots, workers, keep_open: true) { count += 1 }
      index = t.elapsed
      invalidate_maps
      trim = Time.measure { ClearLS::Memory.trim } # parse workers' freed trees (see Memory)
      flush_cache
      @load_stats = LoadStats.new(count, walk, index, trim, start.elapsed)
      Log.info { "indexed #{@entries.size} files" }
    end

    # Indexes *roots* and their require closure, skipping files already
    # indexed. With *keep_open*, an open buffer's existing entry wins over
    # the disk text. Yields once per added entry.
    private def index_files(roots : Array(String), workers : Int32, keep_open : Bool, & : ->) : Nil
      seen = Set(String).new
      todo = [] of String
      roots.each { |p| todo << p if seen.add?(p) }
      add = ->(l : Loaded) do
        entry = l.entry || return
        record_cached(l, entry)
        id = @vfs.id_for(VFS.uri_for(l.path))
        # An open buffer is authoritative; keep its entry.
        return if keep_open && @entries[id]? && @vfs.open?(VFS.uri_for(l.path))
        @entries[id] = entry
        if w = l.words
          @words[id] = w
        else
          @words.delete(id)
        end
        entry.requires.each { |r| todo << r if seen.add?(r) && !@entries.has_key?(id_of(r)) }
        nil
      end
      if workers <= 1
        parser = Syntax::Parser.new
        while path = todo.shift?
          add.call(load_file(parser, path))
          yield
        end
        return
      end

      # Every send happens with fewer than CAPACITY paths in flight, so
      # neither channel's buffer is ever full: no send blocks.
      capacity = 4096
      queue = Channel(String).new(capacity)
      results = Channel(Loaded).new(capacity)
      ctx = Fiber::ExecutionContext::Parallel.new("clear-ls-index", workers)
      workers.times { ctx.spawn { index_worker(queue, results) } }
      in_flight = 0
      loop do
        while in_flight < capacity && (path = todo.shift?)
          queue.send(path)
          in_flight += 1
        end
        break if in_flight == 0
        add.call(results.receive)
        in_flight -= 1
        yield
      end
      queue.close
    end

    # Kept in separate methods on purpose: Crystal closures capture
    # *method-level* variables, so a `parser = ...` local declared anywhere in
    # `index_files` would be one variable shared by every spawned block, i.e.
    # one TSParser used from many threads at once.
    private def index_worker(queue : Channel(String), results : Channel(Loaded)) : Nil
      parser = Syntax::Parser.new
      while path = queue.receive?
        results.send(load_file(parser, path))
      end
    end

    # Reads, parses and lowers one file, resolves its requires and collects
    # its words. Runs on workers: touches only its arguments and read-only
    # project state (resolver, flags, CRYSTAL_PATH).
    private def load_file(parser : Syntax::Parser, path : String) : Loaded
      store = @store
      if store && store.global?(path)
        # Global entries are shared between checkouts: validated by content.
        text = File.read(path)
        words = library_path?(path) ? nil : Index.words(text)
        hash = StableHash.hash(text)
        if tree = store.lookup(path, text.bytesize.to_i64, hash)
          return Loaded.new(path, make_entry(path, tree), words, Cached::GlobalHit)
        end
        meta = Cache::FileMeta.new(path, text.bytesize.to_i64, 0_i64, hash)
        return Loaded.new(path, make_entry(path, Items::Lower.lower(parser.parse(text))), words, Cached::GlobalMiss, meta)
      end
      if local = @local
        # Local entries: size + mtime, so a hit doesn't read the file.
        # Stat before reading: a write in between makes the next lookup miss.
        info = File.info(path)
        if hit = local.lookup(path, info)
          return Loaded.new(path, make_entry(path, hit.tree), hit.words, Cached::LocalHit)
        end
        text = File.read(path)
        words = library_path?(path) ? nil : Index.words(text)
        meta = Cache::FileMeta.new(path, info.size, Cache::Local.mtime(info), 0_u64)
        return Loaded.new(path, make_entry(path, Items::Lower.lower(parser.parse(text))), words, Cached::LocalMiss, meta)
      end
      text = File.read(path)
      words = library_path?(path) ? nil : Index.words(text)
      Loaded.new(path, make_entry(path, Items::Lower.lower(parser.parse(text))), words)
    rescue ex : IO::Error | File::Error
      Log.warn { "cannot read #{path}: #{ex.message}" }
      Loaded.new(path, nil, nil)
    rescue ex
      Log.error(exception: ex) { "failed to index #{path}" }
      Loaded.new(path, nil, nil)
    end

    # Hands a loaded file to its cache layer (indexing fiber only).
    private def record_cached(l : Loaded, entry : Entry) : Nil
      case l.cached
      in .global_miss? then @store.try(&.record(l.path, l.meta.not_nil!, entry.items))
      in .local_miss?  then @local.try(&.record(l.path, l.meta.not_nil!, entry.items, l.words))
      in .local_hit?   then @local.try(&.use(l.path))
      in .global_hit?, .none?
      end
    end

    # Writes cache entries of files indexed since the last flush (after
    # `#load`, and at shutdown for files indexed later).
    def flush_cache : Nil
      @store.try(&.flush)
      @local.try(&.flush)
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
      missing = paths.reject { |p| @entries.has_key?(id_of(p)) }
      index_files(missing, 1, keep_open: false) { } unless missing.empty?
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
  end
end
