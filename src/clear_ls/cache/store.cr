require "yaml"
require "./pack"

module ClearLS::Cache
  # The global cache layer: item trees of the stdlib and of shards in
  # `lib/`, shared by every project (design/persistent-cache.md).
  #
  # One pack per stdlib (`stdlib-<crystal version>-<path digest>`) and per
  # shard version (`shard-<name>-<version>`). An entry is used only when
  # the file's size and content hash match, so a patched file in `lib/`
  # is re-parsed (and not written back: the pristine entry stays shared).
  #
  # Packs are read before indexing starts; `#lookup` is then read-only
  # and safe to call from index workers. `#record` and `#flush` run on the
  # indexing fiber.
  class Store
    # Days without use after which a pack is deleted by `#flush`.
    EVICT_AFTER = 30.days

    getter dir : String
    getter hits = 0
    getter misses = 0

    # A stdlib/shard directory and the pack its files go to.
    private record Area, prefix : String, key : String, kind : PackKind

    @areas = [] of Area
    @packs = {} of String => Pack?
    # New entries per pack key: relative path → (meta, tree).
    @added = {} of String => Hash(String, {FileMeta, Items::ItemTree})
    @hit_count = Atomic(Int32).new(0)
    @miss_count = Atomic(Int32).new(0)

    def initialize(@dir : String, stdlib_dir : String?, crystal_version : String?, project_root : String)
      if stdlib_dir && Dir.exists?(stdlib_dir)
        real = File.realpath(stdlib_dir)
        digest = StableHash.hash(real).to_s(16)
        @areas << Area.new(dir_prefix(stdlib_dir), "stdlib-#{crystal_version || "unknown"}-#{digest}", PackKind::Stdlib)
      end
      Store.shards(project_root).each do |name, version|
        @areas << Area.new(dir_prefix(File.join(project_root, "lib", name)), "shard-#{name}-#{version}", PackKind::Shard)
      end
      @areas.each { |a| @packs[a.key] = read_pack(a) }
    end

    # Default directory: `CLEAR_LS_CACHE_DIR`, else the platform's cache
    # directory plus `clear-ls`.
    def self.default_dir : String
      if dir = ENV["CLEAR_LS_CACHE_DIR"]?.presence
        return dir
      end
      {% if flag?(:darwin) %}
        File.join(Path.home.to_s, "Library", "Caches", "clear-ls")
      {% elsif flag?(:win32) %}
        File.join(ENV["LOCALAPPDATA"]? || Path.home.to_s, "clear-ls")
      {% else %}
        base = ENV["XDG_CACHE_HOME"]?.presence || File.join(Path.home.to_s, ".cache")
        File.join(base, "clear-ls")
      {% end %}
    end

    # Shards installed from a source with a version (`lib/.shards.info`),
    # skipping path dependencies (symlinked into `lib/`: they change like
    # project code and belong to the project layer).
    def self.shards(root : String) : Hash(String, String)
      info = File.join(root, "lib", ".shards.info")
      result = {} of String => String
      return result unless File.file?(info)
      shards = YAML.parse(File.read(info))["shards"]?.try(&.as_h?) || return result
      shards.each do |name, spec|
        name = name.as_s? || next
        version = spec["version"]?.try(&.as_s?) || next
        next if spec["path"]?
        dir = File.join(root, "lib", name)
        next if File.symlink?(dir) || !Dir.exists?(dir)
        result[name] = version
      end
      result
    rescue YAML::ParseException | File::Error
      {} of String => String
    end

    # True when *path* belongs to the global layer.
    def global?(path : String) : Bool
      !area_of(path).nil?
    end

    # The cached tree for *path* if the pack has it with this content.
    def lookup(path : String, size : Int64, hash : UInt64) : Items::ItemTree?
      area = area_of(path) || return nil
      pack = @packs[area.key]? || return miss
      rel = path[area.prefix.size..]
      meta = pack.meta?(rel) || return miss
      return miss unless meta.size == size && meta.hash == hash
      tree = pack.payload(rel).try(&.tree) || return miss
      @hit_count.add(1)
      tree
    rescue FormatError
      miss
    end

    private def miss : Nil
      @miss_count.add(1)
      nil
    end

    # Remembers a freshly lowered tree for the next `#flush`. A file the
    # pack already has with other content (patched in this project's
    # `lib/`) is not recorded: the shared entry stays as published.
    def record(path : String, meta : FileMeta, tree : Items::ItemTree) : Nil
      area = area_of(path) || return
      rel = path[area.prefix.size..]
      return if @packs[area.key]?.try(&.meta?(rel))
      (@added[area.key] ||= {} of String => {FileMeta, Items::ItemTree})[rel] = {meta.copy_with(path: rel), tree}
    end

    # Writes packs that gained entries (old entries + new, atomically),
    # touches the packs that were used, and evicts stale packs. Errors are
    # logged, never raised: the cache is an optimisation.
    def flush : Nil
      @hits, @misses = @hit_count.get, @miss_count.get
      @added.each do |key, entries|
        area = @areas.find { |a| a.key == key } || next
        w = Writer.new(area.kind, key)
        if old = @packs[key]?
          old.files.each_key do |rel|
            next if entries.has_key?(rel)
            tree = old.payload(rel).try(&.tree) || next
            w.add(old.meta?(rel).not_nil!) { |p| p.tree(tree) }
          end
        end
        entries.each_value { |(meta, tree)| w.add(meta) { |p| p.tree(tree) } }
        path = pack_path(key)
        w.write(path)
        @packs[key] = Pack.read(path)
      rescue ex
        Log.warn { "cache: cannot write #{key}: #{ex.message}" }
      end
      @added.clear
      now = Time.utc
      @packs.each { |key, pack| File.touch(pack_path(key), now) if pack rescue nil }
      evict(now)
    end

    private def evict(now : Time) : Nil
      packs = File.join(@dir, "packs")
      return unless Dir.exists?(packs)
      Dir.each_child(packs) do |name|
        full = File.join(packs, name)
        info = File.info?(full) || next
        File.delete?(full) if now - info.modification_time > EVICT_AFTER
      end
    rescue ex : File::Error
      Log.warn { "cache: eviction failed: #{ex.message}" }
    end

    def pack_path(key : String) : String
      File.join(@dir, "packs", key.gsub(/[^A-Za-z0-9._+-]/, '_') + ".pack")
    end

    private def read_pack(area : Area) : Pack?
      path = pack_path(area.key)
      return nil unless File.file?(path)
      pack = Pack.read(path)
      if pack.build_key != Cache.build_key || pack.key != area.key
        Log.info { "cache: #{area.key} written by #{pack.build_key}, ignored" }
        return nil
      end
      pack
    rescue ex : FormatError
      Log.warn { "cache: #{path}: #{ex.message}, ignored" }
      nil
    end

    private def area_of(path : String) : Area?
      @areas.find { |a| path.starts_with?(a.prefix) }
    end

    private def dir_prefix(dir : String) : String
      dir.ends_with?('/') ? dir : dir + "/"
    end
  end
end
