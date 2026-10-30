require "./toolchain"

module ClearLS::Compiler
  # Runs `crystal build --no-codegen` for entry points in the background and
  # reports problems per file.
  #
  # Each entry point has at most one job. A new request for an entry
  # cancels its running job (the files changed under it) and starts again
  # after a short debounce, so `:wall` style bursts compile once. Results of
  # all entry points are merged per file; `on_publish` is called for every
  # file whose merged problems changed, including files that no longer have
  # any (to clear them).
  #
  # Requests and publishing run on fibers of the current execution context;
  # nothing here waits on the caller's fiber.
  #
  # Each entry is compiled by its project's toolchain (`toolchain_for`):
  # in that project's directory, so its `lib/` resolves.
  class Checker
    alias Publish = Proc(String, Array(Problem), Nil)
    alias ToolchainFor = Proc(String, Toolchain)

    property debounce : Time::Span = 150.milliseconds
    property extra_sources : Array(String) = [] of String
    # Extra sources per entry (the facts exporter of its project); wins
    # over `extra_sources`.
    property extra_sources_for : Proc(String, Array(String))? = nil
    property flags : Array(String) = [] of String
    # Called with each completed job result (facts exporter output etc.).
    property on_result : Proc(String, Job::Result, Nil)? = nil

    @generation = Hash(String, Int32).new(0)
    @jobs = {} of String => Job
    # entry → file → problems from its last completed run.
    @results = {} of String => Hash(String, Array(Problem))
    @published = {} of String => Array(Problem)
    @running = 0

    def initialize(@toolchain_for : ToolchainFor, @on_publish : Publish)
    end

    # One toolchain for every entry.
    def self.new(toolchain : Toolchain, on_publish : Publish) : Checker
      new(->(_e : String) { toolchain }, on_publish)
    end

    # True while a job is pending or running.
    def busy? : Bool
      @running > 0
    end

    def check(entries : Array(String)) : Nil
      entries.each { |e| schedule(e) }
    end

    # Cancels everything (shutdown).
    def stop : Nil
      @generation.each_key { |e| @generation[e] += 1 }
      @jobs.each_value(&.cancel)
      @jobs.clear
    end

    # Drops pending runs and results of the entries the block selects
    # (their workspace root was removed), then publishes the files they
    # reported: cleared, unless another entry still reports them.
    def forget(& : String -> Bool) : Nil
      touched = Set(String).new
      (@results.keys + @generation.keys).uniq.each do |entry|
        next unless yield entry
        @generation[entry] += 1
        @jobs.delete(entry).try(&.cancel)
        @results.delete(entry).try { |files| touched.concat(files.keys) }
      end
      touched.each { |file| publish(file) }
    end

    # Problems for *file* as last published.
    def problems(file : String) : Array(Problem)
      @published[file]? || [] of Problem
    end

    private def schedule(entry : String) : Nil
      gen = (@generation[entry] += 1)
      @jobs.delete(entry).try(&.cancel)
      @running += 1
      spawn(name: "clear-ls-check") { run(entry, gen) }
    end

    private def run(entry : String, gen : Int32) : Nil
      sleep @debounce
      return unless @generation[entry] == gen
      toolchain = @toolchain_for.call(entry)
      extra = @extra_sources_for.try(&.call(entry)) || @extra_sources
      job = toolchain.check(entry, extra, @flags)
      @jobs[entry] = job
      result = job.wait
      return unless @generation[entry] == gen
      @jobs.delete(entry)
      if launch = result.launch_error
        Log.warn { "compiler not started: #{launch}" }
        return
      end
      if result.timed_out
        Log.warn { "compiler timed out on #{entry} after #{result.elapsed.total_seconds.round(1)}s" }
        return
      end
      Log.info { "checked #{entry} (in #{toolchain.root}) in #{result.elapsed.total_milliseconds.round}ms (exit #{result.exit_code})" }
      @on_result.try &.call(entry, result)
      record_problems(entry, Toolchain.problems(result, toolchain.root))
    rescue ex
      Log.error(exception: ex) { "check #{entry} failed" }
    ensure
      @running -= 1
    end

    private def record_problems(entry : String, problems : Array(Problem)) : Nil
      by_file = Hash(String, Array(Problem)).new { |h, k| h[k] = [] of Problem }
      problems.each { |p| by_file[p.file] << p }
      old = @results[entry]?
      @results[entry] = by_file
      touched = by_file.keys.to_set
      old.try { |o| touched.concat(o.keys) }
      touched.each { |file| publish(file) }
    end

    private def publish(file : String) : Nil
      merged = [] of Problem
      @results.each_value do |files|
        files[file]?.try &.each { |p| merged << p unless merged.includes?(p) }
      end
      return if (@published[file]? || [] of Problem) == merged
      if merged.empty?
        @published.delete(file)
      else
        @published[file] = merged
      end
      @on_publish.call(file, merged)
    end
  end
end
