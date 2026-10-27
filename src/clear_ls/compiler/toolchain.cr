require "./job"
require "../workspace/project"
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

    # `crystal tool expand` at *file*:*line*:*column* (1-based, codepoint
    # column). The cursor file is passed as a source too: the tool only
    # looks for the cursor in the program's sources, not in required files.
    def expand(entry : String, file : String, line : Int32, column : Int32) : Job
      args = ["tool", "expand", "-f", "json", "--no-color", "-c", "#{file}:#{line}:#{column}", entry]
      args << file unless file == entry
      Job.new(@crystal, args, chdir: @root, timeout: @timeout)
    end

    # `crystal tool context` at a location: local and ivar types in each
    # instantiation of the enclosing def.
    def context(entry : String, file : String, line : Int32, column : Int32) : Job
      args = ["tool", "context", "-f", "json", "--no-color", "-c", "#{file}:#{line}:#{column}", entry]
      args << file unless file == entry
      Job.new(@crystal, args, chdir: @root, timeout: @timeout)
    end

    # `crystal tool format -`: formatted *text* on stdout; a syntax error
    # exits 1 with the message on stderr.
    def format(text : String) : Job
      Job.new(@crystal, ["tool", "format", "--no-color", "-"], chdir: @root, input: text, timeout: 10.seconds)
    end

    # Problems from a finished `#check` job: the compile error (if any),
    # then the warnings. Empty when the job did not complete.
    def self.problems(result : Job::Result, base_dir : String) : Array(Problem)
      return [] of Problem unless result.completed?
      problems = Output.warnings(result.stderr, base_dir)
      if frames = Output.error_frames(result.stderr)
        Output.error(frames).try { |e| problems.unshift(relocate(e, base_dir)) }
      end
      problems
    end

    # An error inside the stdlib or a shard is reported at the last trace
    # frame in the workspace (the user's call that led there), keeping the
    # original location as the last trace entry.
    def self.relocate(problem : Problem, root : String) : Problem
      return problem if workspace_file?(problem.file, root)
      idx = problem.trace.rindex { |f| workspace_file?(f.file, root) } || return problem
      site = problem.trace[idx]
      frame = Frame.new(site.file, site.line, site.column, site.size, problem.message)
      Problem.new(problem.severity, frame, problem.trace[0...idx] + problem.trace[idx + 1..] + [problem.frame])
    end

    # Under *root* but not in its `lib/` (shards).
    def self.workspace_file?(path : String, root : String) : Bool
      prefix = root.ends_with?('/') ? root : root + "/"
      path.starts_with?(prefix) && !path.starts_with?(prefix + "lib/")
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
      Workspace::Project.shard_targets(root)
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
