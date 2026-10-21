require "log"

module ClearLS::Compiler
  Log = ::Log.for("clear-ls.compiler")

  # One compiler subprocess. Output is collected in memory; `#wait` returns
  # when the process exits, is cancelled, or runs past its timeout (then it
  # is killed).
  #
  # Waiting yields the fiber, so jobs are awaited from background fibers and
  # never from the request loop.
  class Job
    record Result,
      exit_code : Int32?,
      stdout : String,
      stderr : String,
      elapsed : Time::Span,
      timed_out : Bool,
      cancelled : Bool,
      launch_error : String? do
      def success? : Bool
        exit_code == 0 && !timed_out && !cancelled && launch_error.nil?
      end

      # Finished on its own (successfully or with a compile error), so the
      # output describes the program.
      def completed? : Bool
        !exit_code.nil? && !timed_out && !cancelled
      end
    end

    getter command : String
    getter args : Array(String)
    @process : Process? = nil
    @launch_error : String? = nil
    @cancelled = false
    @timed_out = false
    @started : Time::Instant
    @stdout = IO::Memory.new
    @stderr = IO::Memory.new
    @result : Result? = nil

    def initialize(@command : String, @args : Array(String), chdir : String? = nil,
                   input : String? = nil, @timeout : Time::Span = 60.seconds,
                   env : Hash(String, String)? = nil)
      @started = Time.instant
      stdin = input ? IO::Memory.new(input) : Process::Redirect::Close
      begin
        @process = Process.new(@command, @args, env: env, chdir: chdir,
          input: stdin, output: @stdout, error: @stderr)
      rescue ex : IO::Error | File::Error
        @launch_error = "#{@command}: #{ex.message}"
      end
      Log.debug { "started #{@command} #{@args.join(' ')}" }
    end

    # Kills the process; `#wait` reports `cancelled`.
    def cancel : Nil
      return if @result
      @cancelled = true
      kill
    end

    def cancelled? : Bool
      @cancelled
    end

    def wait : Result
      @result ||= begin
        exit_code = nil
        if process = @process
          done = Channel(Process::Status).new(1)
          spawn { done.send(process.wait) }
          status = select
          when s = done.receive then s
          when timeout(@timeout)
            @timed_out = true
            kill
            done.receive
          end
          exit_code = status.exit_code? unless @cancelled || @timed_out
        end
        elapsed = Time.instant - @started
        Log.debug { "#{@command} #{@args.first?} exited #{exit_code.inspect} in #{elapsed.total_milliseconds.round}ms" }
        Result.new(exit_code, @stdout.to_s, @stderr.to_s, elapsed, @timed_out, @cancelled, @launch_error)
      end
    end

    private def kill : Nil
      @process.try { |p| p.terminate(graceful: false) unless p.terminated? }
    rescue RuntimeError
      # Already gone.
    end
  end
end
