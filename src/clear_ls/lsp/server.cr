require "log"
require "./transport"
require "./json_rpc"
require "./job"
require "../vfs"
require "../version"
require "../workspace/index"
require "../base/memory"

module ClearLS::LSP
  Log = ::Log.for("clear-ls.lsp")

  # A request answered later from another fiber (it waits on a
  # subprocess). The handler captures what it needs from server state
  # before returning; the block must not read mutable server state.
  class Deferred
    getter block : Proc(JSON::Any)

    def initialize(&@block : -> JSON::Any)
    end
  end

  # Language server main loop.
  #
  # Messages are handled in arrival order on one fiber, so VFS mutations
  # and the requests that follow them are naturally ordered. Long requests
  # (`JOB_METHODS`) run as `Job`s on their own fibers and yield at
  # checkpoints; everything stays on one thread, so the dispatcher only
  # runs between those checkpoints. An edit cancels jobs that read the
  # edited file; `$/cancelRequest` cancels by id.
  class Server
    enum State
      Uninitialized
      Initialized
      ShuttingDown
      Exited
    end

    getter state = State::Uninitialized
    getter vfs = VFS.new
    getter encoding = PositionEncoding::UTF16
    # Process exit code once `exit` arrives: 0 after shutdown, else 1.
    getter exit_code : Int32? = nil
    @index : Workspace::Index? = nil
    # Overridable for tests: builds the project for a workspace root.
    property project_factory : Proc(String, Workspace::Project) = ->(root : String) { Workspace::Project.detect(root) }
    property index_workers : Int32? = nil
    # Persistent cache (`--no-cache` / `initializationOptions.cache`).
    # Off by default for embedders and specs; `clear-ls lsp` turns it on.
    property cache_enabled = false
    # Global cache directory override (else `Cache::Store.default_dir`).
    property cache_dir : String? = nil

    def initialize(@transport : Transport)
    end

    def index : Workspace::Index
      @index || raise ResponseError.new(ErrorCode::ServerNotInitialized, "workspace not indexed")
    end

    def run : Int32
      while @state != State::Exited
        body = @transport.read
        break if body.nil?
        dispatch(body)
      end
      @exit_code || 1
    end

    def dispatch(body : String) : Nil
      msg = begin
        Message.parse(body)
      rescue ex : ResponseError
        @transport.write(JsonRpc.error(nil, ex.code, ex.message || ""))
        return
      end
      return if msg.response?
      touch_activity

      if msg.request?
        handle_request(msg)
      else
        handle_notification(msg)
      end
    end

    # Requests that may search the whole program.
    JOB_METHODS = %w(textDocument/references textDocument/rename callHierarchy/incomingCalls)

    # Running jobs by request id.
    @jobs = {} of RequestId => Job

    def jobs_running : Int32
      @jobs.size
    end

    private def handle_request(msg : Message) : Nil
      id = msg.id
      method = msg.method.not_nil!
      if JOB_METHODS.includes?(method) && @state.initialized? && id
        start_job(id, method, msg.params)
        return
      end
      result = request(method, msg.params)
      if result.is_a?(Deferred)
        spawn(name: "clear-ls-deferred") { finish_deferred(id, method, result) }
      else
        @transport.write(JsonRpc.response(id, result))
      end
    rescue ex : ResponseError
      @transport.write(JsonRpc.error(id, ex.code, ex.message || ""))
    rescue ex
      Log.error(exception: ex) { "request #{method} failed" }
      @transport.write(JsonRpc.error(id, ErrorCode::InternalError, ex.message || ex.class.name))
    end

    # `initializationOptions.budgets`: seconds per request kind
    # (`references`, `rename`, `incomingCalls`; 0 disables; default 5 s),
    # and `maxCandidates` (files per search, default 2000).
    @budget_options = JSON::Any.new({} of String => JSON::Any)
    DEFAULT_BUDGET = 5.seconds

    private def budget_for(method : String) : Time::Span?
      key = method.split('/').last
      secs = @budget_options[key]?.try { |v| v.as_f? || v.as_i?.try(&.to_f) }
      return DEFAULT_BUDGET if secs.nil?
      secs <= 0 ? nil : secs.seconds
    end

    private def start_job(id : RequestId, method : String, params : JSON::Any) : Nil
      job = Job.new(id, method)
      job.deadline = budget_for(method).try { |b| job.started + b }
      @jobs[id] = job
      spawn(name: "clear-ls-job") do
        begin
          result = job.run { request(method, params) }
          result = result.block.call if result.is_a?(Deferred)
          @transport.write(JsonRpc.response(id, result)) unless job.cancelled? && request_cancelled?(job)
        rescue ex : ResponseError
          @transport.write(JsonRpc.error(id, ex.code, ex.message || ""))
        rescue ex
          Log.error(exception: ex) { "request #{method} failed" }
          @transport.write(JsonRpc.error(id, ErrorCode::InternalError, ex.message || ex.class.name))
        ensure
          @jobs.delete(id)
          # A search parses many files; their freed trees stay in malloc
          # arenas otherwise (`Memory`).
          ClearLS::Memory.trim if @jobs.empty?
          Log.debug { "job #{method} #{id}: #{(Time.instant - job.started).total_milliseconds.round}ms#{job.cancelled? ? " (cancelled)" : ""}" }
        end
      end
    end

    # A job cancelled after its last checkpoint finished anyway; the
    # client asked for an error, so send that.
    private def request_cancelled?(job : Job) : Bool
      begin
        job.checkpoint
        false
      rescue ex : ResponseError
        @transport.write(JsonRpc.error(job.id, ex.code, ex.message || ""))
        true
      end
    end

    # Cancels jobs that read *file* (its contents changed under them).
    private def cancel_jobs_reading(file : FileId) : Nil
      @jobs.each_value do |j|
        j.cancel(ErrorCode::ContentModified, "#{@vfs.uri(file).split('/').last} changed during #{j.method.split('/').last}") if j.read?(file)
      end
    end

    # A file's text changed: jobs that read it are stale; a declaration
    # change rebuilds the DefMaps every job works with, so all are.
    private def edited(file : FileId, decls_changed : Bool) : Nil
      warmup_restart if decls_changed
      return if @jobs.empty?
      if decls_changed
        @jobs.each_value { |j| j.cancel(ErrorCode::ContentModified, "declarations changed during #{j.method.split('/').last}") }
      else
        cancel_jobs_reading(file)
      end
    end

    private def cancel_request(params : JSON::Any) : Nil
      raw = params["id"]?.try(&.raw)
      id = case raw
           when Int64  then raw
           when String then raw
           end
      return unless id
      @jobs[id]?.try(&.cancel(ErrorCode::RequestCancelled, "cancelled"))
    end

    private def finish_deferred(id : RequestId?, method : String, deferred : Deferred) : Nil
      @transport.write(JsonRpc.response(id, deferred.block.call))
    rescue ex : ResponseError
      @transport.write(JsonRpc.error(id, ex.code, ex.message || ""))
    rescue ex
      Log.error(exception: ex) { "request #{method} failed" }
      @transport.write(JsonRpc.error(id, ErrorCode::InternalError, ex.message || ex.class.name))
    end

    private def request(method : String, params : JSON::Any)
      if @state.uninitialized? && method != "initialize"
        raise ResponseError.new(ErrorCode::ServerNotInitialized, "server not initialized")
      end
      if @state.shutting_down?
        raise ResponseError.new(ErrorCode::InvalidRequest, "server is shutting down")
      end

      case method
      when "initialize"         then initialize_request(params)
      when "shutdown"           then stop_compiler; @index.try(&.flush_cache); @state = State::ShuttingDown; nil
      when "clearLs/syntaxTree" then syntax_tree(params)
      when "clearLs/expandMacro" then expand_macro(params)
      when "clearLs/clearCache" then clear_cache
      else                           feature_request(method, params)
      end
    end

    private def handle_notification(msg : Message) : Nil
      method = msg.method.not_nil!
      params = msg.params
      case method
      when "exit"
        @exit_code = @state.shutting_down? ? 0 : 1
        @state = State::Exited
        return
      end
      return if @state.uninitialized? || @state.shutting_down?

      case method
      when "initialized"                     then load_index; start_compiler; start_warmup
      when "textDocument/didOpen"            then did_open(params)
      when "textDocument/didChange"          then did_change(params)
      when "textDocument/didClose"           then did_close(params)
      when "textDocument/didSave"            then compiler_saved(params.dig("textDocument", "uri").as_s)
      when "workspace/didChangeWatchedFiles" then did_change_watched(params)
      when "$/cancelRequest"                 then cancel_request(params)
      when "$/setTrace"                      then nil
      else
        Log.debug { "ignored notification #{method}" }
      end
    rescue ex
      Log.error(exception: ex) { "notification #{method} failed" }
    end

    # -- lifecycle ----------------------------------------------------------

    private def initialize_request(params : JSON::Any)
      raise ResponseError.new(ErrorCode::InvalidRequest, "already initialized") unless @state.uninitialized?

      offered = params.dig?("capabilities", "general", "positionEncodings").try(&.as_a?) || [] of JSON::Any
      encodings = offered.compact_map { |e| e.as_s?.try { |s| PositionEncoding.from_lsp?(s) } }
      # Byte offsets are native for us; prefer them, then utf-32, else utf-16.
      @encoding = [PositionEncoding::UTF8, PositionEncoding::UTF32].find { |e| encodings.includes?(e) } || PositionEncoding::UTF16
      @root = workspace_root(params)
      @client_capabilities = params["capabilities"]? || @client_capabilities
      @references_options = params.dig?("initializationOptions", "references") || @references_options
      @budget_options = params.dig?("initializationOptions", "budgets") || @budget_options
      read_compiler_options(params)
      params.dig?("initializationOptions", "warmup", "enabled").try(&.as_bool?).try { |v| @warmup_enabled = v }
      if opts = params.dig?("initializationOptions", "cache")
        opts["enabled"]?.try(&.as_bool?).try { |v| @cache_enabled = v }
        opts["dir"]?.try(&.as_s?).try { |v| @cache_dir = v }
      end
      @state = State::Initialized

      {
        capabilities: {
          positionEncoding: @encoding.to_lsp,
          textDocumentSync: {
            openClose: true,
            change:    2, # incremental
            save:      {includeText: false},
          },
        }.merge(feature_capabilities),
        serverInfo: {name: "clear-ls", version: VERSION},
      }
    end

    @root : String = Dir.current
    @client_capabilities = JSON::Any.new({} of String => JSON::Any)

    # The client's root, or the project containing it when the client
    # opened a directory inside a project (no `shard.yml` of its own).
    private def workspace_root(params : JSON::Any) : String
      root = client_root(params)
      return root if File.file?(File.join(root, "shard.yml"))
      Workspace::Project.find_root(File.join(root, "x")) || root
    end

    private def client_root(params : JSON::Any) : String
      if folders = params["workspaceFolders"]?.try(&.as_a?)
        folders.each { |f| (p = VFS.path_for(f["uri"].as_s)) && return p }
      end
      params["rootUri"]?.try(&.as_s?).try { |u| VFS.path_for(u) } ||
        params["rootPath"]?.try(&.as_s?) || Dir.current
    end

    # Indexes the workspace. Runs synchronously on `initialized`: requests
    # queue behind it, which keeps every answer consistent with a complete
    # index (stdlib + workspace takes well under a second).
    private def load_index : Nil
      return if @index
      elapsed = Time.measure do
        project = @project_factory.call(@root)
        idx = Workspace::Index.new(project, @vfs)
        attach_cache(idx, project) if @cache_enabled
        workers = @index_workers
        workers ? idx.load(workers) : idx.load
        # Open buffers may have arrived before indexing; they win.
        @vfs.snapshot.files.each { |f| idx.update(f) if f.overlay? }
        idx.def_map # build now rather than on the first request
        @index = idx
      end
      Log.info { "index ready: #{index.size} files in #{elapsed.total_milliseconds.round}ms#{cache_summary}" }
      restore_facts
    end

    private def attach_cache(idx : Workspace::Index, project : Workspace::Project) : Nil
      idx.store = Cache::Store.new(@cache_dir || Cache::Store.default_dir, project.stdlib_dir, project.crystal_version, project.root)
      idx.local = Cache::Local.new(project.root, local_cache_key(project))
    rescue ex
      Log.warn { "cache disabled: #{ex.message}" }
      idx.store = nil
      idx.local = nil
    end

    # What local entries depend on besides file contents: resolved
    # requires aren't stored, so only the toolchain identity matters for
    # the facts.
    private def local_cache_key(project : Workspace::Project) : String
      "#{project.crystal_version || "unknown"} #{project.target_triple} #{project.crystal_path.join(':')}"
    end

    private def cache_summary : String
      idx = @index || return ""
      g = idx.store
      l = idx.local
      return "" unless g || l
      " (cache: global #{g.try(&.hits) || 0}/#{(g.try(&.hits) || 0) + (g.try(&.misses) || 0)}, " \
      "local #{l.try(&.hits) || 0}/#{(l.try(&.hits) || 0) + (l.try(&.misses) || 0)})"
    end

    # `clearLs/clearCache`: drops this project's local cache and the
    # global packs it uses, then re-indexes from source.
    private def clear_cache
      idx = @index || raise ResponseError.new(ErrorCode::ServerNotInitialized, "workspace not indexed")
      project = idx.project
      idx.store.try { |st| st.pack_keys.each { |k| File.delete?(st.pack_path(k)) } }
      Cache::Local.clear(project.root)
      @index = nil
      @typings.clear
      load_index
      warmup_restart
      # This session's facts are current: keep them in the new index.
      unless @entry_facts.empty?
        index.local.try(&.write_facts(@entry_facts))
        apply_entry_facts
      end
      {cleared: true, files: index.size}
    end

    # -- text sync ----------------------------------------------------------

    private def did_open(params : JSON::Any) : Nil
      doc = params["textDocument"]
      state = @vfs.open(doc["uri"].as_s, doc["text"].as_s, doc["version"].as_i64)
      @index.try(&.update(state))
      compiler_opened(state.uri)
      Log.debug { "didOpen #{state.uri} v#{state.version} (#{state.text.bytesize} bytes)" }
    end

    private def did_change(params : JSON::Any) : Nil
      doc = params["textDocument"]
      changes = params["contentChanges"].as_a.map do |change|
        text = change["text"].as_s
        if range = change["range"]?
          {position(range["start"]), position(range["end"]), text}
        else
          {nil.as(LineCol?), nil.as(LineCol?), text}
        end
      end
      state = @vfs.change(doc["uri"].as_s, doc["version"].as_i64, changes, @encoding)
      decls_changed = @index.try(&.update(state))
      edited(state.id, !!decls_changed)
      Log.debug do
        ranges = state.tree.changed_ranges.try(&.join(", ")) || "full"
        "didChange #{state.uri} v#{state.version}: #{changes.size} edit(s), changed [#{ranges}], error=#{state.tree.has_error?}, decls_changed=#{decls_changed}"
      end
    end

    private def did_close(params : JSON::Any) : Nil
      uri = params["textDocument"]["uri"].as_s
      @vfs.close(uri)
      evict_bodies(@vfs.id_for(uri))
      # Back to the disk contents (or forget an unsaved untitled buffer).
      if idx = @index
        if state = @vfs.file?(uri)
          edited(state.id, idx.update(state))
        else
          edited(@vfs.id_for(uri), true)
          idx.remove(@vfs.id_for(uri))
        end
      end
    end

    # FileChangeType: 1 created, 2 changed, 3 deleted.
    private def did_change_watched(params : JSON::Any) : Nil
      params["changes"].as_a.each do |c|
        uri = c["uri"].as_s
        @vfs.disk_changed(uri)
        compiler_saved(uri) if c["type"]?.try(&.as_i) != 3
        idx = @index || next
        next if @vfs.open?(uri)
        if c["type"]?.try(&.as_i) == 3
          idx.remove(@vfs.id_for(uri))
        elsif state = @vfs.load(uri)
          edited(state.id, idx.update(state))
        end
      end
    end

    # -- debug --------------------------------------------------------------

    # `clearLs/syntaxTree {textDocument: {uri}}` → S-expression of the CST.
    private def syntax_tree(params : JSON::Any)
      uri = params.dig("textDocument", "uri").as_s
      state = @vfs.file?(uri) || @vfs.load(uri) ||
              raise ResponseError.new(ErrorCode::InvalidParams, "unknown document #{uri}")
      state.tree.root.sexp
    end

    private def position(json : JSON::Any) : LineCol
      LineCol.new(json["line"].as_i64.to_u32, json["character"].as_i64.to_u32)
    end
  end
end
