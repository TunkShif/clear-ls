require "log"
require "./transport"
require "./json_rpc"
require "./job"
require "./settings"
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
    # One index per workspace root, in root order; the first is the
    # primary one (`Server#index` outside a request).
    getter indexes = [] of Workspace::Index
    # Overridable for tests: builds the project for a workspace root.
    property project_factory : Proc(String, Workspace::Project) = ->(root : String) { Workspace::Project.detect(root) }
    property index_workers : Int32? = nil
    getter settings = Settings.new
    # What the host allows, on top of the settings: embedders and specs
    # get neither the persistent cache nor the warm-up unless they ask;
    # `clear-ls lsp` allows both (`--no-cache` disallows the cache).
    property cache_allowed = false
    property warmup_allowed = false

    def initialize(@transport : Transport)
    end

    # The index the current request is answered from (`#with_index`),
    # else the primary one.
    def index : Workspace::Index
      @scoped[Fiber.current.object_id]? || primary_index
    end

    def primary_index : Workspace::Index
      @indexes.first? || raise ResponseError.new(ErrorCode::ServerNotInitialized, "workspace not indexed")
    end

    # Index per fiber: requests and jobs run on their own fibers, so a
    # job that yields keeps its index while others answer from theirs.
    @scoped = {} of UInt64 => Workspace::Index
    # Index of the last workspace document a request came from: answers
    # for files under no root (a stdlib file opened by go-to-definition).
    @last_index : Workspace::Index? = nil

    # Runs the block with *idx* as `#index` on this fiber.
    def with_index(idx : Workspace::Index, & : -> T) : T forall T
      fid = Fiber.current.object_id
      prev = @scoped[fid]?
      @scoped[fid] = idx
      begin
        yield
      ensure
        prev ? (@scoped[fid] = prev) : @scoped.delete(fid)
      end
    end

    # The index whose root holds *path* (longest root: a nested folder
    # wins over its parent).
    def owner_index(path : String) : Workspace::Index?
      best = nil.as(Workspace::Index?)
      @indexes.each do |i|
        root = i.project.root
        next unless path.starts_with?(root.ends_with?('/') ? root : root + "/")
        best = i if best.nil? || root.size > best.project.root.size
      end
      best
    end

    # The index that answers for *file*: its root's, else the last used
    # one when it has the file, else the first that has it, else the
    # primary one.
    def index_for(file : FileId) : Workspace::Index
      if (path = VFS.path_for(@vfs.uri(file))) && (own = owner_index(path))
        return own
      end
      if (last = @last_index) && last.entry?(file) && @indexes.includes?(last)
        return last
      end
      @indexes.find(&.entry?(file)) || primary_index
    end

    # Indexes to update when *file* changes: its root's and every index
    # that has it (the primary one for a file nobody has yet).
    private def indexes_touching(file : FileId) : Array(Workspace::Index)
      return [] of Workspace::Index if @indexes.empty?
      own = VFS.path_for(@vfs.uri(file)).try { |p| owner_index(p) }
      list = @indexes.select { |i| i.same?(own) || i.entry?(file) }
      list << primary_index if list.empty?
      list
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
      canonicalize(msg)

      if msg.request?
        handle_request(msg)
      else
        handle_notification(msg)
      end
    end

    # Document URIs of *msg* under the names the server uses (see
    # `VFS#canonical_uri`), so code that reads paths from params agrees
    # with the interned ids. A document opened through a symlink into a
    # root is aliased to its name under that root first.
    private def canonicalize(msg : Message) : Nil
      doc = msg.params.as_h?.try(&.["textDocument"]?).try(&.as_h?) || return
      uri = doc["uri"]?.try(&.as_s?) || return
      alias_document(uri) if msg.method == "textDocument/didOpen"
      canonical = @vfs.canonical_uri(uri)
      doc["uri"] = JSON::Any.new(canonical) unless canonical == uri
    end

    private def alias_document(uri : String) : Nil
      return if @indexes.empty?
      path = VFS.path_for(@vfs.canonical_uri(uri)) || return
      return if owner_index(path)
      real = File.realpath(path) rescue return
      return if real == path
      target = @vfs.canonical_uri(VFS.uri_for(real))
      @vfs.alias_file(uri, target) if VFS.path_for(target).try { |p| owner_index(p) }
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

    # Seconds per request kind (`budgets.*`; 0 disables).
    private def budget_for(method : String) : Time::Span?
      secs = @settings.float("budgets.#{method.split('/').last}")
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
      when "shutdown"           then stop_compiler; @indexes.each(&.flush_cache); @state = State::ShuttingDown; nil
      when "clearLs/syntaxTree" then syntax_tree(params)
      when "clearLs/expandMacro" then expand_macro(params)
      when "clearLs/clearCache" then clear_cache
      else
        idx = request_index(method, params)
        idx ? with_index(idx) { feature_request(method, params) } : feature_request(method, params)
      end
    end

    # The index for a request on a document (or a hierarchy item); nil
    # for workspace-wide requests.
    private def request_index(method : String, params : JSON::Any) : Workspace::Index?
      return nil if @indexes.size <= 1
      file = if method.starts_with?("typeHierarchy/") && (f = params.dig?("item", "data", "file").try(&.as_i64?))
               FileId.new(f.to_u32)
             elsif uri = params.dig?("textDocument", "uri").try(&.as_s?) || params.dig?("item", "uri").try(&.as_s?)
               @vfs.id_for(uri)
             end
      return nil unless file
      idx = index_for(file)
      @last_index = idx if VFS.path_for(@vfs.uri(file)).try { |p| owner_index(p) }
      idx
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
      when "workspace/didChangeConfiguration" then did_change_configuration(params)
      when "workspace/didChangeWorkspaceFolders" then did_change_folders(params)
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
      @folders = client_roots(params)
      @roots = roots_of(@folders)
      @client_capabilities = params["capabilities"]? || @client_capabilities
      @settings.apply(params["initializationOptions"]?)
      @state = State::Initialized

      {
        capabilities: {
          positionEncoding: @encoding.to_lsp,
          textDocumentSync: {
            openClose: true,
            change:    2, # incremental
            save:      {includeText: false},
          },
          workspace: {
            workspaceFolders: {supported: true, changeNotifications: true},
          },
        }.merge(feature_capabilities),
        serverInfo: {name: "clear-ls", version: VERSION},
      }
    end

    # Project roots of the workspace folders, primary first.
    getter roots = [] of String
    @client_capabilities = JSON::Any.new({} of String => JSON::Any)

    # The client's workspace folders (paths), in order.
    @folders = [] of String

    # Project roots of the client's workspace folders (else `rootUri`):
    # each folder, or the project containing it when the folder is a
    # directory inside a project (no `shard.yml` of its own). Folders of
    # one project share its root.
    private def roots_of(folders : Array(String)) : Array(String)
      folders.map { |r| project_root(r) }.uniq
    end

    private def project_root(dir : String) : String
      return dir if File.file?(File.join(dir, "shard.yml"))
      Workspace::Project.find_root(File.join(dir, "x")) || dir
    end

    private def client_roots(params : JSON::Any) : Array(String)
      if folders = params["workspaceFolders"]?.try(&.as_a?)
        roots = folders.compact_map { |f| f["uri"]?.try(&.as_s?).try { |u| VFS.path_for(u) } }
        return roots unless roots.empty?
      end
      [params["rootUri"]?.try(&.as_s?).try { |u| VFS.path_for(u) } ||
        params["rootPath"]?.try(&.as_s?) || Dir.current]
    end

    # Indexes every root. Runs synchronously on `initialized`: requests
    # queue behind it, which keeps every answer consistent with a complete
    # index (stdlib + workspace takes well under a second).
    @loaded = false

    private def load_index : Nil
      return unless @indexes.empty?
      @loaded = true
      @roots.each { |r| add_root(r) }
      restore_facts
    end

    # `workspace/didChangeWorkspaceFolders`: index the roots that appear
    # (like at startup: requests wait), drop those that no folder maps to
    # any more. The primary root stays first while it remains.
    private def did_change_folders(params : JSON::Any) : Nil
      event = params["event"]
      paths = ->(key : String) do
        (event[key]?.try(&.as_a?) || [] of JSON::Any).compact_map { |f| f["uri"]?.try(&.as_s?).try { |u| VFS.path_for(u) } }
      end
      removed = paths.call("removed").map { |p| p.rchop('/') }
      @folders.reject! { |f| removed.includes?(f.rchop('/')) }
      paths.call("added").each { |p| @folders << p unless @folders.includes?(p) }
      new_roots = roots_of(@folders)
      # Without folders the last root stays: files still need an index.
      new_roots = @roots.first(1) if new_roots.empty?
      gone = @roots - new_roots
      fresh = new_roots - @roots
      return if gone.empty? && fresh.empty?
      @roots = new_roots
      return unless @loaded # not indexed yet: `initialized` will
      gone.each { |r| remove_root(r) }
      fresh.each do |r|
        idx = add_root(r)
        restore_facts(idx)
        check_root(idx) if @checker
      end
      # Keep the indexes in root order (the primary one first).
      @indexes.sort_by! { |i| @roots.index(i.project.root) || @roots.size }
      warmup_restart unless fresh.empty?
    end

    # Drops a root's index, its typings and its diagnostics.
    private def remove_root(root : String) : Nil
      idx = @indexes.find { |i| i.project.root == root } || return
      idx.flush_cache
      @indexes.delete(idx)
      @last_index = nil if @last_index.same?(idx)
      @typings.reject! { |_, (m, _)| @indexes.none?(&.live_map?(m)) }
      # A job on the dropped index answers from stale views.
      @jobs.each_value { |j| j.cancel(ErrorCode::ContentModified, "workspace folder removed during #{j.method.split('/').last}") }
      forget_root(root)
      # Open buffers of the root now belong to the index that answers
      # for them (a view of their own, or another root's).
      @vfs.snapshot.files.each do |f|
        next unless f.overlay? && VFS.path_for(f.uri).try(&.starts_with?(root.ends_with?('/') ? root : root + "/"))
        indexes_touching(f.id).each(&.update(f))
      end
      Log.info { "removed root #{root}" }
    end

    # Indexes one root. Library files another index has already parsed
    # are reused (`Index#seed`).
    private def add_root(root : String) : Workspace::Index
      # Clients may name the folder through a symlink and its files by
      # real path (Neovim on macOS: `/var/...` vs `/private/var/...`).
      @vfs.claim(root)
      if (real = (File.realpath(root) rescue nil)) && real != root
        @vfs.alias_dir(real, root)
      end
      idx = nil.as(Workspace::Index?)
      elapsed = Time.measure do
        project = @project_factory.call(root)
        i = Workspace::Index.new(project, @vfs)
        attach_cache(i, project) if cache_enabled?
        unless @indexes.empty?
          seed = {} of String => {Int64, Int64, Items::ItemTree}
          @indexes.each { |o| seed.merge!(o.library_trees) }
          i.seed = seed
        end
        workers = @index_workers
        workers ? i.load(workers) : i.load
        i.seed = nil
        @indexes << i
        # Open buffers may have arrived before indexing; they win.
        @vfs.snapshot.files.each { |f| i.update(f) if f.overlay? && indexes_touching(f.id).includes?(i) }
        i.def_map # build now rather than on the first request
        idx = i
      end
      idx = idx.not_nil!
      seeded = idx.seeded > 0 ? ", #{idx.seeded} shared" : ""
      Log.info { "index ready: #{root}: #{idx.size} files in #{elapsed.total_milliseconds.round}ms#{cache_summary(idx)}#{seeded}" }
      idx
    end

    private def attach_cache(idx : Workspace::Index, project : Workspace::Project) : Nil
      idx.store = Cache::Store.new(@settings.string?("cache.dir") || Cache::Store.default_dir, project.stdlib_dir, project.crystal_version, project.root)
      local = idx.local = Cache::Local.new(project.root, local_cache_key(project))
      project.children = ->(dir : String) { local.children(dir) }
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

    private def cache_summary(idx : Workspace::Index) : String
      g = idx.store
      l = idx.local
      return "" unless g || l
      " (cache: global #{g.try(&.hits) || 0}/#{(g.try(&.hits) || 0) + (g.try(&.misses) || 0)}, " \
      "local #{l.try(&.hits) || 0}/#{(l.try(&.hits) || 0) + (l.try(&.misses) || 0)}, " \
      "dirs #{l.try(&.dir_hits) || 0}/#{(l.try(&.dir_hits) || 0) + (l.try(&.dir_misses) || 0)})"
    end

    # `clearLs/clearCache`: drops every root's local cache and the global
    # packs they use, then re-indexes from source.
    private def clear_cache
      raise ResponseError.new(ErrorCode::ServerNotInitialized, "workspace not indexed") if @indexes.empty?
      @indexes.each do |idx|
        idx.store.try { |st| st.pack_keys.each { |k| File.delete?(st.pack_path(k)) } }
        Cache::Local.clear(idx.project.root)
      end
      @indexes.clear
      @last_index = nil
      @typings.clear
      load_index
      warmup_restart
      # This session's facts are current: keep them in the new index.
      unless @entry_facts.empty?
        write_all_facts
        apply_entry_facts
      end
      {cleared: true, files: @indexes.sum(&.size)}
    end

    private def cache_enabled? : Bool
      @cache_allowed && @settings.bool("cache.enabled")
    end

    # `settings.clearLs` (or `settings` itself). Settings read once at
    # startup take effect on restart; the rest apply now.
    private def did_change_configuration(params : JSON::Any) : Nil
      raw = params["settings"]?
      section = raw.try { |r| r["clearLs"]? || r["clear-ls"]? || r }
      changed = @settings.apply(section)
      return if changed.empty?
      Log.info { "settings changed: #{changed.join(", ")}" }
      later = changed.select { |c| Settings::KEYS.find(&.path.==(c)).try(&.restart) }
      Log.info { "restart to apply: #{later.join(", ")}" } unless later.empty?
      settings_changed(changed)
    end

    # Hook for settings that apply immediately (inlay hints, warm-up).
    private def settings_changed(changed : Array(String)) : Nil
      refresh_views(["inlayHint"]) if changed.any?(&.starts_with?("inlayHints."))
      if changed.includes?("warmup.enabled")
        @settings.bool("warmup.enabled") ? warmup_restart : (@warmup_generation += 1)
      end
    end

    # -- text sync ----------------------------------------------------------

    private def did_open(params : JSON::Any) : Nil
      doc = params["textDocument"]
      state = @vfs.open(doc["uri"].as_s, doc["text"].as_s, doc["version"].as_i64)
      indexes_touching(state.id).each(&.update(state))
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
      decls_changed = indexes_touching(state.id).map(&.update(state)).any?
      edited(state.id, decls_changed)
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
      return if @indexes.empty?
      if state = @vfs.file?(uri)
        edited(state.id, indexes_touching(state.id).map(&.update(state)).any?)
      else
        id = @vfs.id_for(uri)
        edited(id, true)
        @indexes.each(&.remove(id))
      end
    end

    # FileChangeType: 1 created, 2 changed, 3 deleted.
    private def did_change_watched(params : JSON::Any) : Nil
      params["changes"].as_a.each do |c|
        uri = c["uri"].as_s
        @vfs.disk_changed(uri)
        compiler_saved(uri) if c["type"]?.try(&.as_i) != 3
        next if @indexes.empty? || @vfs.open?(uri)
        if c["type"]?.try(&.as_i) == 3
          @indexes.each(&.remove(@vfs.id_for(uri)))
        elsif state = @vfs.load(uri)
          edited(state.id, indexes_touching(state.id).map(&.update(state)).any?)
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
