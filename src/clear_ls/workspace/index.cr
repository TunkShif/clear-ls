require "./project"
require "../vfs"
require "../semantics/def_map"
require "./compiler_facts"

module ClearLS::Workspace
  # Item trees for every indexed file plus the merged `DefMap`.
  #
  # Files come from two sources:
  # - the require closure of the prelude and of every workspace file
  #   (stdlib, shards in `lib/`, required project files);
  # - all `.cr` files under the project root.
  #
  # Only item trees are kept for closed files; syntax trees are dropped
  # after lowering. Open buffers come from the VFS and override disk.
  #
  # The DefMap is rebuilt from item trees when any file's item fingerprint
  # changes. Edits inside method bodies keep the fingerprint, so they do not
  # rebuild it (`#rebuilds` counts rebuilds for tests).
  class Index
    record Entry, path : String, items : Items::ItemTree, fingerprint : UInt64, requires : Array(String)

    getter project : Project
    getter rebuilds = 0
    @entries = {} of FileId => Entry
    @def_map : Semantics::DefMap? = nil
    @facts = CompilerFacts.new
    # Members added from compiler facts in the current DefMap.
    getter fact_members = 0

    getter facts

    # Replaces the compiler facts; rebuilds the DefMap when they changed.
    def facts=(facts : CompilerFacts) : Nil
      return if facts == @facts
      @facts = facts
      @def_map = nil
    end

    def initialize(@project : Project, @vfs : VFS)
    end

    def def_map : Semantics::DefMap
      @def_map ||= begin
        @rebuilds += 1
        map = Semantics::DefMap.new(@project.flags)
        @entries.each { |id, e| map.add_file(id, e.items) }
        unless @facts.empty?
          elapsed = Time.measure do
            @fact_members = @facts.apply(map, ->(path : String) { @vfs.id_for(VFS.uri_for(path)) }, ->saved_text(String))
          end
          Log.debug { "applied compiler facts: #{@fact_members} members in #{elapsed.total_milliseconds.round(1)}ms" }
        end
        map
      end
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

    # Indexes the prelude closure and workspace files from disk, then their
    # require closure. Parses in parallel with *workers* threads.
    def load(workers : Int32 = default_workers) : Nil
      roots = @project.source_files
      @project.prelude.try { |p| roots.unshift(p) }
      pending = roots.to_set
      seen = Set(String).new
      until pending.empty?
        batch = pending.to_a.reject { |p| seen.includes?(p) }
        seen.concat(batch)
        pending = Set(String).new
        parse_batch(batch, workers).each do |path, items|
          next unless items
          id = @vfs.id_for(VFS.uri_for(path))
          # An open buffer is authoritative; keep its entry.
          next if @entries[id]? && @vfs.open?(VFS.uri_for(path))
          entry = make_entry(path, items)
          @entries[id] = entry
          entry.requires.each { |r| pending << r unless seen.includes?(r) }
        end
      end
      @def_map = nil
      Log.info { "indexed #{@entries.size} files" }
    end

    # Re-lowers an open/changed file from its current VFS state. Returns true
    # when declarations changed (DefMap invalidated).
    def update(state : FileState) : Bool
      path = VFS.path_for(state.uri) || state.uri
      items = Items::Lower.lower(state.tree)
      entry = make_entry(path, items)
      old = @entries[state.id]?
      changed = old.nil? || old.fingerprint != entry.fingerprint
      if changed
        @entries[state.id] = entry
        @def_map = nil
        load_missing(entry.requires)
      else
        # Same declarations, possibly moved by a body edit: the DefMap's
        # sites share the old items, so move those (no rebuild).
        old = old.not_nil!
        old.items.move_to(items)
        @entries[state.id] = Entry.new(path, old.items, old.fingerprint, entry.requires)
        @def_map.try(&.positions_changed)
      end
      changed
    end

    # Removes a file (deleted from disk).
    def remove(file : FileId) : Nil
      @def_map = nil if @entries.delete(file)
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

    private def load_missing(paths : Array(String)) : Nil
      missing = paths.reject { |p| @entries.has_key?(@vfs.id_for(VFS.uri_for(p))) }
      return if missing.empty?
      parse_batch(missing, 1).each do |path, items|
        next unless items
        @entries[@vfs.id_for(VFS.uri_for(path))] = make_entry(path, items)
      end
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
