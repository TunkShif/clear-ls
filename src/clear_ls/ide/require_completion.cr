require "yaml"
require "../workspace/project"

module ClearLS::IDE
  # Completion inside the string of a `require` (Phase 13, decision 6).
  #
  # - Local (`./`, `../`): `.cr` files of the directory without the
  #   extension, subdirectories as `dir/`. A bare directory is never a
  #   valid require (`./src/migrations`: can't find file) unless it holds
  #   `dir/dir.cr`.
  # - Stdlib: one directory level per request; internals hidden.
  # - Shards: only the names of direct dependencies installed in `lib/`;
  #   no subpaths, no transitive shards.
  # - No globs.
  #
  # Every item is checked with the resolver and kept only when it
  # resolves to the file it names. Written requires are unaffected: hover,
  # definition and links resolve everything (`Analysis#resolve_require`).
  class RequireCompletion
    record Item, label : String, insert : String, directory : Bool, target : String?, detail : String,
      documentation : String? = nil

    # Context of a cursor inside a require string: the typed path up to
    # the cursor, and the byte range of its last segment (what an item
    # replaces).
    record Context, typed : String, segment_start : UInt32, segment_end : UInt32

    # Stdlib names never offered at the top level: always loaded by the
    # prelude (its own `require "x"` lines), or compiler internals.
    HIDDEN_STD = %w(prelude empty docs_main docs_pseudo_methods compiler crystal llvm intrinsics primitives)

    def initialize(@project : Workspace::Project, @from_file : String?)
    end

    # The require string around *offset* in *text*, from the line text
    # (works for unterminated strings: `require "./fo|`).
    def self.context(text : String, offset : UInt32) : Context?
      line_start = offset
      while line_start > 0 && text.byte_at(line_start - 1) != '\n'.ord
        line_start -= 1
      end
      before = text.byte_slice(line_start, offset - line_start)
      m = before.match(/\A\s*require\s+"([^"\\]*)\z/) || return nil
      typed = m[1]
      last = typed.rpartition('/')[2]
      seg_start = offset - last.bytesize
      # The segment ends at the next `/`, `"` or end of line.
      seg_end = offset
      while seg_end < text.bytesize && !text.byte_at(seg_end).chr.in?('/', '"', '\n')
        seg_end += 1
      end
      Context.new(typed, seg_start, seg_end)
    end

    def items(ctx : Context) : Array(Item)
      typed = ctx.typed
      cut = typed.rindex('/')
      dir_part = cut ? typed[0..cut] : ""
      prefix = cut ? typed[(cut + 1)..] : typed
      result = if typed.starts_with?("./") || typed.starts_with?("../") || typed == "." || typed == ".."
                 local(dir_part, prefix)
               elsif typed.starts_with?('/')
                 [] of Item
               elsif dir_part.empty?
                 shards(prefix) + stdlib("", prefix)
               else
                 stdlib(dir_part, prefix)
               end
      # Names shadowed by a shard (lib/ comes first) appear once.
      seen = Set(String).new
      result.select { |i| seen.add?(i.label) }
    end

    # -- local ----------------------------------------------------------------------

    private def local(dir_part : String, prefix : String) : Array(Item)
      from = @from_file || return [] of Item
      return [] of Item if dir_part.empty? # `.` / `..` still being typed
      dir = File.expand_path(dir_part, File.dirname(from))
      items = [] of Item
      listing(dir).each do |(name, is_dir)|
        next unless name.starts_with?(prefix)
        full = File.join(dir, name)
        if is_dir
          items << Item.new("#{name}/", "#{name}/", true, nil, "directory") if has_sources?(full)
          # `dir/dir.cr` makes the directory itself requireable.
          own = File.join(full, "#{name}.cr")
          if File.file?(own) && !File.file?(File.join(dir, "#{name}.cr")) && resolves_to?("#{dir_part}#{name}", own)
            items << Item.new(name, name, false, own, "file (#{name}/#{name}.cr)")
          end
        elsif name.ends_with?(".cr")
          next if File.expand_path(full) == File.expand_path(from)
          stem = name.rchop(".cr")
          items << Item.new(stem, stem, false, full, "file") if resolves_to?("#{dir_part}#{stem}", full)
        end
      end
      items
    end

    # -- stdlib ---------------------------------------------------------------------

    private def stdlib(dir_part : String, prefix : String) : Array(Item)
      std = @project.stdlib_dir || return [] of Item
      # Hidden at any depth: `lib_*` bindings.
      return [] of Item if dir_part.split('/').any?(&.starts_with?("lib_"))
      top = dir_part.empty?
      return [] of Item if top && HIDDEN_STD.includes?(dir_part.rchop('/'))
      return [] of Item if !top && HIDDEN_STD.includes?(dir_part.split('/').first)
      dir = File.join(std, dir_part)
      hidden = top ? HIDDEN_STD + prelude_requires(std) : [] of String
      entries = listing(dir)
      dirs = entries.select(&.[1]).map(&.[0]).to_set
      items = [] of Item
      entries.each do |(name, is_dir)|
        stem = is_dir ? name : name.rchop(".cr")
        next unless is_dir || name.ends_with?(".cr")
        next unless stem.starts_with?(prefix)
        next if stem.starts_with?("lib_") || hidden.includes?(stem)
        if is_dir
          # A file of the same name gets one item: the file, continuing
          # into the directory when `/` is typed.
          next if File.file?(File.join(dir, "#{name}.cr"))
          next unless has_sources?(File.join(dir, name))
          items << Item.new("#{name}/", "#{name}/", true, nil, "directory")
        else
          full = File.join(dir, name)
          next unless resolves_to?("#{dir_part}#{stem}", full)
          detail = dirs.includes?(stem) ? "stdlib (also #{stem}/)" : "stdlib"
          items << Item.new(stem, stem, false, full, detail)
        end
      end
      items
    end

    @prelude_requires : Array(String)? = nil

    # Names the prelude requires itself (`require "array"`): always loaded.
    private def prelude_requires(std : String) : Array(String)
      @prelude_requires ||= begin
        text = File.read(File.join(std, "prelude.cr")) rescue ""
        text.scan(/^\s*require\s+"([^"\/]+)"/m).map(&.[1])
      end
    end

    # -- shards ---------------------------------------------------------------------

    private def shards(prefix : String) : Array(Item)
      items = [] of Item
      direct_dependencies.each do |name, version|
        next unless name.starts_with?(prefix)
        target = @project.resolver.resolve(name, @from_file).first? || next
        # Only shards installed in `lib/` (a stdlib name is not a shard).
        next unless target.starts_with?(File.join(@project.root, "lib") + "/")
        items << Item.new(name, name, false, target, version ? "shard #{version}" : "shard",
          shard_description(name))
      end
      items
    end

    # `dependencies` and `development_dependencies` of the project's
    # `shard.yml`, with the installed version (from `lib/<name>/shard.yml`).
    private def direct_dependencies : Array({String, String?})
      path = File.join(@project.root, "shard.yml")
      return [] of {String, String?} unless File.file?(path)
      yaml = YAML.parse(File.read(path))
      names = [] of String
      %w(dependencies development_dependencies).each do |key|
        yaml[key]?.try(&.as_h?).try &.each_key { |k| k.as_s?.try { |s| names << s } }
      end
      names.uniq.map do |n|
        version = begin
          YAML.parse(File.read(File.join(@project.root, "lib", n, "shard.yml")))["version"]?.try(&.as_s?)
        rescue
          nil
        end
        {n, version}
      end
    rescue YAML::ParseException
      [] of {String, String?}
    end

    # `description` of the installed shard's `shard.yml`.
    private def shard_description(name : String) : String?
      YAML.parse(File.read(File.join(@project.root, "lib", name, "shard.yml")))["description"]?.try(&.as_s?).try(&.strip.presence)
    rescue
      nil
    end

    # -- helpers --------------------------------------------------------------------

    # Children of *dir* (name, directory?), sorted; hidden entries and
    # symlinked directories left out (`lib/marten/lib` → `..`).
    private def listing(dir : String) : Array({String, Bool})
      return [] of {String, Bool} unless Dir.exists?(dir)
      result = [] of {String, Bool}
      Dir.each_child(dir) do |name|
        next if name.starts_with?('.')
        full = File.join(dir, name)
        info = File.info?(full, follow_symlinks: false) || next
        if info.symlink?
          next if File.directory?(full)
          result << {name, false} if File.file?(full)
        else
          result << {name, info.directory?}
        end
      end
      result.sort_by!(&.[0])
    end

    private def has_sources?(dir : String) : Bool
      Dir.each_child(dir) do |name|
        return true if name.ends_with?(".cr") || File.directory?(File.join(dir, name))
      end
      false
    end

    private def resolves_to?(path : String, file : String) : Bool
      @project.resolver.resolve(path, @from_file).first? == File.expand_path(file)
    end
  end
end
