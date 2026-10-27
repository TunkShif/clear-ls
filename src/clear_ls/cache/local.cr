require "file_utils"
require "./pack"
require "../workspace/compiler_facts"

module ClearLS::Cache
  # The project-local layer, `<root>/.clear-ls/cache/`: item trees and word
  # sets of every indexed file outside the global layer (project files,
  # path dependencies, extra `CRYSTAL_PATH` entries), and the compiler
  # facts of the last session (design/persistent-cache.md).
  #
  # Entries are validated by size and modification time (nanoseconds):
  # a hit needs no read of the file. Requires are resolved on every load
  # (glob requires and new files would make a cached resolution stale;
  # resolving costs ~7 ms on Marten).
  class Local
    record Hit, tree : Items::ItemTree, words : Set(UInt64)?

    getter dir : String
    getter hits = 0
    getter misses = 0
    @pack : Pack? = nil
    @hit_count = Atomic(Int32).new(0)
    @miss_count = Atomic(Int32).new(0)
    # Entries to write: path → (meta, tree, words).
    @fresh = {} of String => {FileMeta, Items::ItemTree, Set(UInt64)?}
    @used = Set(String).new
    @dirty = false

    # *key* identifies what the entries depend on besides file contents
    # (Crystal version, target): a pack with another key is ignored.
    def initialize(@root : String, @key : String)
      @dir = File.join(Local.dir_for(@root), "cache")
      @pack = read(items_path)
    end

    def self.dir_for(root : String) : String
      File.join(root, ".clear-ls")
    end

    def items_path : String
      File.join(@dir, "items.pack")
    end

    def facts_path : String
      File.join(@dir, "facts.pack")
    end

    # The cached entry of *path* when its size and mtime still match.
    # Safe from index workers (read-only after construction).
    def lookup(path : String, info : File::Info) : Hit?
      pack = @pack || return miss
      meta = pack.meta?(path) || return miss
      return miss unless meta.size == info.size && meta.mtime == Local.mtime(info)
      r = pack.payload(path) || return miss
      tree = r.tree
      words = read_words(r)
      @hit_count.add(1)
      Hit.new(tree, words)
    rescue FormatError
      miss
    end

    private def miss : Nil
      @miss_count.add(1)
      nil
    end

    def self.mtime(info : File::Info) : Int64
      info.modification_time.to_unix_ns.to_i64
    end

    # Marks *path* as part of this session's index (hit or fresh).
    def use(path : String) : Nil
      @used << path
    end

    # A file lowered from disk this session.
    def record(path : String, meta : FileMeta, tree : Items::ItemTree, words : Set(UInt64)?) : Nil
      @fresh[path] = {meta, tree, words}
      @used << path
      @dirty = true
    end

    # Writes the pack when files were added, changed or dropped since it
    # was read. Errors are logged.
    def flush : Nil
      @hits, @misses = @hit_count.get, @miss_count.get
      old = @pack
      dropped = old ? old.files.each_key.any? { |p| !@used.includes?(p) } : false
      return unless @dirty || dropped
      w = Writer.new(PackKind::Local, @key)
      if old
        old.files.each_key do |path|
          next if @fresh.has_key?(path) || !@used.includes?(path)
          r = old.payload(path) || next
          tree = r.tree
          words = read_words(r)
          w.add(old.meta?(path).not_nil!) { |p| p.tree(tree); write_words(p, words) }
        end
      end
      @fresh.each_value { |(meta, tree, words)| w.add(meta) { |p| p.tree(tree); write_words(p, words) } }
      ensure_dir
      w.write(items_path)
      @pack = Pack.read(items_path)
      @fresh.clear
      @dirty = false
    rescue ex
      Log.warn { "cache: cannot write #{items_path}: #{ex.message}" }
    end

    # Compiler facts per entry point from the last session (empty when
    # none or the pack is stale).
    def read_facts : Hash(String, Workspace::CompilerFacts)
      result = {} of String => Workspace::CompilerFacts
      pack = read(facts_path) || return result
      pack.files.each_key do |entry|
        r = pack.payload(entry) || next
        methods = Array(Compiler::Exporter::MethodFact).new(r.u32) do
          Compiler::Exporter::MethodFact.new(r.str!, r.bool, r.str!, r.str!, r.u32.to_i32, r.u32.to_i32, r.str!)
        end
        ivars = Array(Compiler::Exporter::IvarFact).new(r.u32) do
          Compiler::Exporter::IvarFact.new(r.str!, r.str!, r.str!)
        end
        digests = {} of String => UInt64
        r.u32.times { digests[r.str!] = r.u64 }
        result[entry] = Workspace::CompilerFacts.new(methods, ivars, digests)
      end
      result
    rescue FormatError
      {} of String => Workspace::CompilerFacts
    end

    def write_facts(facts : Hash(String, Workspace::CompilerFacts)) : Nil
      w = Writer.new(PackKind::Local, @key)
      facts.each do |entry, f|
        w.add(FileMeta.new(entry, 0_i64, 0_i64, 0_u64)) do |p|
          p.u32(f.methods.size.to_u32)
          f.methods.each do |m|
            p.str(m.owner); p.bool(m.class_level); p.str(m.visibility); p.str(m.file)
            p.u32(m.line.to_u32); p.u32(m.column.to_u32); p.str(m.header)
          end
          p.u32(f.ivars.size.to_u32)
          f.ivars.each { |v| p.str(v.owner); p.str(v.name); p.str(v.type) }
          p.u32(f.digests.size.to_u32)
          f.digests.each { |path, d| p.str(path); p.u64(d) }
        end
      end
      ensure_dir
      w.write(facts_path)
    rescue ex
      Log.warn { "cache: cannot write #{facts_path}: #{ex.message}" }
    end

    # Deletes the project's cache directory.
    def self.clear(root : String) : Nil
      FileUtils.rm_rf(File.join(dir_for(root), "cache"))
    end

    private def ensure_dir : Nil
      Dir.mkdir_p(@dir)
      # `.clear-ls/.gitignore` with `*`: the directory never shows in
      # `git status`, without touching the project's own .gitignore.
      ignore = File.join(Local.dir_for(@root), ".gitignore")
      File.write(ignore, "*\n") unless File.exists?(ignore)
    end

    private def write_words(p : Payload, words : Set(UInt64)?) : Nil
      p.bool(!words.nil?)
      return unless words
      p.u32(words.size.to_u32)
      words.each { |h| p.u64(h) }
    end

    private def read_words(r : Reader) : Set(UInt64)?
      return nil unless r.bool
      n = r.u32
      set = Set(UInt64).new(n.to_i)
      n.times { set << r.u64 }
      set
    end

    private def read(path : String) : Pack?
      return nil unless File.file?(path)
      pack = Pack.read(path)
      if pack.build_key != Cache.build_key || pack.key != @key
        Log.info { "cache: #{path} written by #{pack.build_key} for #{pack.key}, ignored" }
        return nil
      end
      pack
    rescue ex : FormatError
      Log.warn { "cache: #{path}: #{ex.message}, ignored" }
      nil
    end
  end
end
