require "yaml"
require "./job"
require "./output"

module ClearLS::Compiler
  # The `crystal` executable as used for one workspace.
  class Toolchain
    getter crystal : String
    getter root : String
    property timeout : Time::Span

    def initialize(@crystal : String, @root : String, @timeout : Time::Span = 120.seconds)
    end

    # `crystal build --no-codegen` of *entry* plus *extra* sources (e.g. the
    # facts exporter). Runs in the workspace root so `lib/` resolves.
    def check(entry : String, extra : Array(String) = [] of String, flags : Array(String) = [] of String) : Job
      args = ["build", "--no-codegen", "-f", "json", "--no-color"]
      flags.each { |f| args << "-D" << f }
      args << entry
      args.concat(extra)
      Job.new(@crystal, args, chdir: @root, timeout: @timeout)
    end

    # Problems from a finished `#check` job: the compile error (if any),
    # then the warnings. Empty when the job did not complete.
    def self.problems(result : Job::Result, base_dir : String) : Array(Problem)
      return [] of Problem unless result.completed?
      problems = Output.warnings(result.stderr, base_dir)
      if frames = Output.error_frames(result.stderr)
        Output.error(frames).try { |e| problems.unshift(e) }
      end
      problems
    end
  end

  # Which programs to compile to check a file.
  #
  # Crystal checks whole programs, so a file is checked through every
  # program that requires it: the `targets` in `shard.yml` whose require
  # closure contains it. Files outside every target (scripts, specs) are
  # compiled on their own.
  class EntryPoints
    getter targets : Array(String)

    def initialize(@root : String, targets : Array(String)? = nil)
      @targets = targets || self.class.shard_targets(@root)
    end

    # `targets.*.main` from `shard.yml`, as absolute paths of existing
    # files.
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

    # Entry points that check *file*. *requires* gives the resolved
    # requires of an indexed file.
    def for(file : String, & : String -> Array(String)?) : Array(String)
      found = @targets.select do |target|
        closure_includes?(target, file) { |p| yield p }
      end
      found.empty? ? [file] : found
    end

    private def closure_includes?(target : String, file : String, & : String -> Array(String)?) : Bool
      return true if target == file
      seen = Set{target}
      queue = [target]
      while path = queue.pop?
        (yield(path) || next).each do |req|
          return true if req == file
          queue << req if seen.add?(req)
        end
      end
      false
    end
  end
end
