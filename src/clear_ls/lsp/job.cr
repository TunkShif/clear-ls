require "./json_rpc"

module ClearLS::LSP
  # A long-running request (references, rename, incoming calls) that runs
  # on its own fiber and gives way to other requests at checkpoints.
  #
  # Everything still runs on one thread: a job only interleaves with the
  # dispatcher at `checkpoint`. Between checkpoints server state may
  # change (an edit), so a job records which files it read, and an edit
  # of one of them cancels it with `ContentModified`. `$/cancelRequest`
  # cancels it with `RequestCancelled`. A cancelled job raises
  # `ResponseError` from its next checkpoint; the error is the response.
  class Job
    getter id : RequestId?
    getter method : String
    getter started = Time.instant
    @cancel : ErrorCode? = nil
    @reason = ""
    @files = Set(FileId).new
    # Deadline from the request's budget (nil: none).
    property deadline : Time::Instant? = nil
    # What the job covered so far, for budget messages ("61 of 84
    # candidate files searched").
    property progress = ""

    def initialize(@id, @method)
    end

    def cancel(code : ErrorCode, reason : String) : Nil
      @cancel ||= code
      @reason = reason if @reason.empty?
    end

    def cancelled? : Bool
      !@cancel.nil?
    end

    def read(file : FileId) : Nil
      @files << file
    end

    def read?(file : FileId) : Bool
      @files.includes?(file)
    end

    # Raises if cancelled or over budget, else lets other fibers run.
    def checkpoint : Nil
      if code = @cancel
        raise ResponseError.new(code, @reason)
      end
      if (d = @deadline) && Time.instant > d
        secs = (Time.instant - @started).total_seconds.round(1)
        raise ResponseError.new(ErrorCode::RequestFailed,
          "#{@method.split('/').last} stopped after #{secs} s#{@progress.empty? ? "" : ": #{@progress}"}")
      end
      Fiber.yield
    end

    # The job of the current fiber, if any (checked by deep code that has
    # no job parameter, like the reference search).
    @@current = {} of UInt64 => Job

    def self.current : Job?
      @@current[Fiber.current.object_id]?
    end

    def run(& : -> T) : T forall T
      @@current[Fiber.current.object_id] = self
      yield
    ensure
      @@current.delete(Fiber.current.object_id)
    end

    # Checkpoint of the current job, a no-op outside jobs (specs, probes).
    def self.checkpoint : Nil
      current.try(&.checkpoint)
    end

    def self.read(file : FileId) : Nil
      current.try(&.read(file))
    end
  end
end
