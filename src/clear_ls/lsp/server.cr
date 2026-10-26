require "log"
require "./transport"
require "./json_rpc"
require "../vfs"
require "../version"
require "../workspace/index"

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
  # Messages are handled one at a time in arrival order on one fiber, so VFS
  # mutations and the requests that follow them are naturally ordered.
  # Long-running analysis will later run on snapshots in other fibers.
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

      if msg.request?
        handle_request(msg)
      else
        handle_notification(msg)
      end
    end

    private def handle_request(msg : Message) : Nil
      id = msg.id
      method = msg.method.not_nil!
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
      when "shutdown"           then stop_compiler; @state = State::ShuttingDown; nil
      when "clearLs/syntaxTree" then syntax_tree(params)
      when "clearLs/expandMacro" then expand_macro(params)
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
      when "initialized"                     then load_index; start_compiler
      when "textDocument/didOpen"            then did_open(params)
      when "textDocument/didChange"          then did_change(params)
      when "textDocument/didClose"           then did_close(params)
      when "textDocument/didSave"            then compiler_saved(params.dig("textDocument", "uri").as_s)
      when "workspace/didChangeWatchedFiles" then did_change_watched(params)
      when "$/cancelRequest", "$/setTrace"   then nil
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
      read_compiler_options(params)
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

    private def workspace_root(params : JSON::Any) : String
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
        idx = Workspace::Index.new(@project_factory.call(@root), @vfs)
        workers = @index_workers
        workers ? idx.load(workers) : idx.load
        # Open buffers may have arrived before indexing; they win.
        @vfs.snapshot.files.each { |f| idx.update(f) if f.overlay? }
        idx.def_map # build now rather than on the first request
        @index = idx
      end
      Log.info { "index ready: #{index.size} files in #{elapsed.total_milliseconds.round}ms" }
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
          idx.update(state)
        else
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
          idx.update(state)
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
