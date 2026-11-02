require "log"
require "yaml"
require "./require_resolver"

module ClearLS::Workspace
  Log = ::Log.for("clear-ls.workspace")

  # Toolchain and layout of one Crystal project.
  class Project
    getter root : String
    # Absolute `CRYSTAL_PATH` entries (`lib` expanded against root).
    getter crystal_path : Array(String)
    getter stdlib_dir : String?
    getter crystal_version : String?
    getter target_triple : String
    getter flags : Set(String)
    getter resolver : RequireResolver

    # Lists a directory for the source walk (`Cache::Local#children`
    # when the cache is on).
    property children : Proc(String, Array(String)) = ->(dir : String) { Dir.children(dir) }

    def initialize(@root : String, crystal_path : Array(String), @stdlib_dir, @crystal_version, @target_triple)
      @crystal_path = crystal_path.map { |p| File.expand_path(p, @root) }
      @flags = Items.flags_for_triple(@target_triple)
      @resolver = RequireResolver.new(@crystal_path)
    end

    # Queries the `crystal` executable (`crystal env`, `crystal --version`).
    # Falls back to `lib` only when no compiler is found. Runs in *root*,
    # so a version manager picks that project's Crystal (`.tool-versions`).
    # Both commands run at once (13–15 ms each). Not cached per executable:
    # `crystal` may be a version manager's shim that picks a Crystal per
    # directory.
    def self.detect(root : String, crystal : String = ENV["CRYSTAL"]? || "crystal") : Project
      env_run = start(crystal, ["env", "CRYSTAL_PATH", "CRYSTAL_VERSION"], root)
      version_run = start(crystal, ["--version"], root)
      env = finish(env_run).try(&.lines) || [] of String
      path = (env[0]? || "lib").split(Process::PATH_DELIMITER, remove_empty: true)
      version = env[1]?.presence
      triple = finish(version_run).try { |text| text[/Default target: (\S+)/, 1]? } || default_triple
      stdlib = path.map { |p| File.expand_path(p, root) }.find { |p| File.file?(File.join(p, "prelude.cr")) }
      Log.info { "project #{root}: crystal #{version || "?"} target #{triple} stdlib #{stdlib || "not found"}" }
      new(root, path, stdlib, version, triple)
    end

    # Workspace source files: everything under root except `lib/` (shards,
    # indexed through requires instead), hidden directories, and nested
    # directories with their own `shard.yml` (separate projects).
    def source_files : Array(String)
      files = [] of String
      walk(@root, files, top: true)
      files.sort!
    end

    # Files that make up the project's program view: the `shard.yml`
    # targets (their require closure is followed by the index), else
    # everything under `src/`, else every source file. Without a
    # `shard.yml` the root is not a project (a folder of loose files):
    # no roots, every file gets a view of its own.
    def program_roots : Array(String)
      return [] of String unless File.file?(File.join(@root, "shard.yml"))
      targets = Project.shard_targets(@root)
      return targets unless targets.empty?
      src = File.join(@root, "src")
      if Dir.exists?(src)
        files = [] of String
        walk(src, files, top: false)
        return files.sort! unless files.empty?
      end
      source_files
    end

    # `targets.*.main` from `shard.yml` under *root*, as absolute paths of
    # existing files.
    def self.shard_targets(root : String) : Array(String)
      path = File.join(root, "shard.yml")
      return [] of String unless File.file?(path)
      yaml = YAML.parse(File.read(path))
      targets = yaml["targets"]?.try(&.as_h?) || return [] of String
      targets.values.compact_map do |t|
        main = t["main"]?.try(&.as_s?) || next
        full = File.expand_path(main, root)
        full if File.file?(full)
      end.uniq!
    rescue YAML::ParseException
      [] of String
    end

    # Nearest directory at or above *path*'s directory with a `shard.yml`.
    def self.find_root(path : String) : String?
      dir = File.dirname(path)
      loop do
        return dir if File.file?(File.join(dir, "shard.yml"))
        parent = File.dirname(dir)
        return nil if parent == dir
        dir = parent
      end
    end

    def prelude : String?
      @stdlib_dir.try { |d| File.join(d, "prelude.cr") }
    end

    private def walk(dir : String, files : Array(String), top : Bool) : Nil
      @children.call(dir).each do |name|
        next if name.starts_with?('.')
        full = File.join(dir, name)
        if File.directory?(full)
          next if top && name.in?("lib", "bin", "build", "vendor", "node_modules")
          next if File.file?(File.join(full, "shard.yml")) # nested project
          walk(full, files, top: false) unless File.symlink?(full)
        elsif name.ends_with?(".cr")
          files << full
        end
      end
    rescue File::Error
    end

    # Starts *cmd*; `finish` reads its output (small enough for the pipe
    # buffer, so several can run before any is read).
    private def self.start(cmd : String, args : Array(String), dir : String) : Process?
      dir = Dir.current unless Dir.exists?(dir)
      Process.new(cmd, args, output: Process::Redirect::Pipe, error: Process::Redirect::Close, chdir: dir)
    rescue File::NotFoundError | IO::Error
      nil
    end

    private def self.finish(process : Process?) : String?
      process = process || return nil
      text = process.output.gets_to_end
      process.wait.success? ? text : nil
    rescue IO::Error
      nil
    end

    private def self.default_triple : String
      {% if flag?(:darwin) %}
        {% if flag?(:aarch64) %} "aarch64-apple-darwin" {% else %} "x86_64-apple-darwin" {% end %}
      {% elsif flag?(:win32) %}
        "x86_64-pc-windows-msvc"
      {% elsif flag?(:aarch64) %}
        "aarch64-unknown-linux-gnu"
      {% else %}
        "x86_64-unknown-linux-gnu"
      {% end %}
    end
  end
end
