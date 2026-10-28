require "./diagnostics"

module ClearLS::LSP
  # Compiler-confirmed local types (`crystal tool context`).
  #
  # Hovering a local in a saved, unmodified file starts a background
  # context run for its def (unless one is cached or running). The result
  # is cached by (file, saved text, def range), and later hovers add
  # `compiler: T` to the inferred type. One context run at a time; a hover
  # elsewhere waits for the next run.
  #
  # The tool falls back to the top-level context for a def that is never
  # instantiated. For a def body a result counts only when it binds every
  # parameter (or, without parameters, has `self` or a local of the def).
  class Server
    record ContextKey, file : String, digest : UInt64, body : TextRange

    # nil value: running or failed (don't retry this text).
    @contexts = {} of ContextKey => Array(Hash(String, String))?
    @context_running = false

    getter contexts

    def context_running? : Bool
      @context_running
    end

    # Types the compiler reported for *name* in *body* of *state*, or nil
    # (not available yet; a run may have started).
    private def compiler_types(state : FileState, body : HIR::Body, name : String) : Array(String)?
      return unless compiler_enabled? && @settings.bool("compiler.contextHover")
      path = VFS.path_for(state.uri) || return
      return unless File.file?(path)
      saved = File.read(path)
      return unless state.text == saved
      key = ContextKey.new(path, saved.hash, body.range)
      if @contexts.has_key?(key)
        ctxs = @contexts[key] || return
        types = ctxs.compact_map { |c| c[name]? }.uniq
        return types.empty? ? nil : types
      end
      start_context(key, state, saved, body)
      nil
    end

    private def start_context(key : ContextKey, state : FileState, saved : String, body : HIR::Body) : Nil
      return if @context_running
      in_def = body.range != state.tree.root.range
      params = body.bindings.select(&.kind.param?).map(&.name)
      own = body.bindings.map(&.name)
      # A location inside the body: the end of the def's first line.
      lines = LineIndex.new(saved)
      line = lines.line_of(body.range.start)
      pos = lines.position(lines.line_range(line).end, PositionEncoding::UTF32)
      entry = (program_entries(state.uri) || [key.file]).first
      job = toolchain.context(entry, key.file, pos.line.to_i + 1, pos.column.to_i + 1)
      @contexts[key] = nil
      @context_running = true
      spawn(name: "clear-ls-context") do
        result = job.wait
        @contexts[key] = parse_contexts(result, in_def, params, own) if result.completed?
        Log.debug { "context #{key.file}:#{line + 1} in #{result.elapsed.total_milliseconds.round}ms: #{@contexts[key].try(&.size) || "none"}" }
      ensure
        @context_running = false
      end
    end

    private def parse_contexts(result : Compiler::Job::Result, in_def : Bool, params : Array(String), own : Array(String)) : Array(Hash(String, String))?
      json = (JSON.parse(result.stdout) rescue nil) || return nil
      return nil unless json["status"]?.try(&.as_s) == "ok"
      ctxs = json["contexts"].as_a.map { |c| c.as_h.transform_values(&.as_s) }
      if in_def
        ctxs.select! do |c|
          params.empty? ? (c.has_key?("self") || own.any? { |n| c.has_key?(n) }) : params.all? { |p| c.has_key?(p) }
        end
      end
      ctxs.empty? ? nil : ctxs
    end
  end
end
