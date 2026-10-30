require "./server"
require "../ide/references"

module ClearLS::LSP
  # Background warm-up (Phase 11): infers every body of the project's
  # workspace files once, so the summary caches a references search needs
  # are filled before the first search.
  #
  # Runs on its own fiber after indexing, one body per step. It only
  # works while the server is idle: each step waits until no request or
  # notification arrived for `IDLE`, and no job is running. Any message
  # pushes the next step back. A declaration change (new DefMaps, so the
  # typings it filled are gone) restarts it from the first file.
  #
  # Setting `warmup.enabled` (and `Server#warmup_allowed`).
  class Server
    IDLE = 300.milliseconds

    private def warmup_enabled? : Bool
      @warmup_allowed && @settings.bool("warmup.enabled")
    end
    getter warmup_done = false
    getter warmup_bodies = 0
    @last_activity = Time.instant
    @warmup_generation = 0

    # Called for every incoming message.
    private def touch_activity : Nil
      @last_activity = Time.instant
    end

    private def warmup_restart : Nil
      return unless warmup_enabled? && !@indexes.empty?
      @warmup_generation += 1
      @warmup_done = false
      start_warmup
    end

    private def start_warmup : Nil
      return unless warmup_enabled?
      gen = @warmup_generation
      spawn(name: "clear-ls-warmup") do
        begin
          warmup(gen)
        rescue ex
          Log.error(exception: ex) { "warm-up failed" }
        end
      end
    end

    private def warmup(gen : Int32) : Nil
      started = Time.instant
      busy = Time::Span.zero
      files = warmup_files
      bodies = 0
      files.each do |path|
        return unless warmup_wait(gen)
        uri = VFS.uri_for(path)
        state = @vfs.file?(uri) || @vfs.load(uri) || next
        # Own bodies, dropped after the file: the server's body cache would
        # keep every file's HIR (~120 MB on Marten); a search re-lowers the
        # bodies it needs (lowering is cheap, inference is what's cached).
        file_bodies = IDE::Bodies.new(state)
        idx = index_for(state.id)
        typing = with_index(idx) { typing(state) }
        starts = [0_u32]
        state.tree.root.walk { |n| starts << n.start_byte + 1 if n.kind.method_def?; true }
        starts.each do |s|
          return unless warmup_wait(gen)
          t = Time.instant
          # Call facts only (what a search reads), not the whole Infer:
          # keeping every body's would cost ~460 MB on Marten.
          with_index(idx) { typing.call_facts(state, file_bodies, s) }
          busy += t.elapsed
          bodies += 1
        end
        # Summaries are keyed by file revision, so the file stays loaded
        # (a reload would bump it) as after a references search.
      end
      @warmup_bodies = bodies
      @warmup_done = true
      ClearLS::Memory.trim
      Log.info { "warm-up: #{bodies} bodies in #{files.size} files, #{busy.total_milliseconds.round}ms busy, #{(Time.instant - started).total_milliseconds.round}ms total" }
    end

    # Workspace source files of the project (the reference search's
    # candidates): not stdlib or shards.
    private def warmup_files : Array(String)
      files = Set(String).new
      @indexes.each do |idx|
        idx.each_entry { |id, e| files << e.path unless idx.library_file?(id) }
      end
      files.to_a.sort!
    end

    # Waits until the server is idle; false when the warm-up is stale
    # (restarted, or the server is stopping).
    private def warmup_wait(gen : Int32) : Bool
      loop do
        return false unless gen == @warmup_generation && @state.initialized?
        idle = Time.instant - @last_activity
        if idle >= IDLE && @jobs.empty?
          Fiber.yield
          return gen == @warmup_generation && @state.initialized?
        end
        sleep(idle >= IDLE ? 50.milliseconds : IDLE - idle)
      end
    end
  end
end
