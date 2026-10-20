require "../items"

module ClearLS::Workspace
  # Crystal require resolution, mirroring the compiler's `CrystalPath`
  # (compiler/crystal/crystal_path.cr).
  #
  # - `./x`, `../x`: relative to the requiring file's directory.
  # - `x`, `x/y`: searched in each `CRYSTAL_PATH` entry (`lib`, stdlib, ...),
  #   with shard layouts (`x/src/x.cr`, `x/src/y.cr`, ...).
  # - `dir/*`, `dir/**`: all `.cr` files in the directory (recursively).
  class RequireResolver
    getter entries : Array(String)

    # *entries* are absolute directories; relative `CRYSTAL_PATH` entries
    # such as `lib` should be expanded against the project root first.
    def initialize(@entries : Array(String))
    end

    # Absolute paths for `require "path"` in *from_file*. Empty when not found.
    def resolve(path : String, from_file : String?) : Array(String)
      if path.starts_with?('.')
        return [] of String unless from_file
        find_relative(path, File.dirname(from_file)) || [] of String
      else
        @entries.each do |dir|
          if found = find_relative(path, dir)
            return found
          end
        end
        [] of String
      end
    end

    private def find_relative(filename : String, dir : String) : Array(String)?
      if filename.ends_with?("/*") || (recursive = filename.ends_with?("/**"))
        sub = File.join(dir, filename[0..filename.rindex!('/')])
        return nil unless Dir.exists?(sub)
        files = [] of String
        gather(sub, files, !!recursive)
        return files
      end
      each_expansion(filename, dir) do |candidate|
        full = File.expand_path(candidate)
        return [full] if File.file?(full)
      end
      nil
    end

    private def each_expansion(filename : String, relative_to : String, &) : Nil
      relative = "#{relative_to}/#{filename}"
      yield relative.ends_with?(".cr") ? relative : "#{relative}.cr"

      is_relative = filename.starts_with?('.')
      shard_name, _, shard_path = filename.partition('/')
      if !is_relative && !shard_path.empty?
        shard_src = "#{relative_to}/#{shard_name}/src"
        stem = shard_path.rchop(".cr")
        yield "#{shard_src}/#{stem}.cr"
        yield "#{shard_src}/#{shard_name}/#{stem}.cr"
        yield "#{relative}/#{File.basename(relative, ".cr")}.cr"
        yield "#{shard_src}/#{shard_path}/#{stem}.cr"
        yield "#{shard_src}/#{shard_name}/#{shard_path}/#{stem}.cr"
      else
        base = File.basename(relative, ".cr")
        yield "#{relative}/#{base}.cr"
        yield "#{relative}/src/#{base}.cr" unless is_relative
      end
    end

    private def gather(dir : String, files : Array(String), recursive : Bool) : Nil
      subdirs = [] of String
      own = [] of String
      Dir.each_child(dir) do |name|
        full = File.join(dir, name)
        if File.directory?(full)
          subdirs << full if recursive
        elsif name.ends_with?(".cr")
          own << File.expand_path(full)
        end
      end
      files.concat(own.sort!)
      subdirs.sort!.each { |d| gather(d, files, recursive) }
    end
  end
end
