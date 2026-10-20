require "log"
require "./transport"
require "./json_rpc"
require "../vfs"
require "../version"

module ClearLS::LSP
  Log = ::Log.for("clear-ls.lsp")

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

    def initialize(@transport : Transport)
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
      @transport.write(JsonRpc.response(id, result))
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
      when "shutdown"           then @state = State::ShuttingDown; nil
      when "clearLs/syntaxTree" then syntax_tree(params)
      else
        raise ResponseError.new(ErrorCode::MethodNotFound, "unhandled method #{method}")
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
      when "initialized"                     then nil
      when "textDocument/didOpen"            then did_open(params)
      when "textDocument/didChange"          then did_change(params)
      when "textDocument/didClose"           then did_close(params)
      when "textDocument/didSave"            then nil
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
      @state = State::Initialized

      {
        capabilities: {
          positionEncoding: @encoding.to_lsp,
          textDocumentSync: {
            openClose: true,
            change:    2, # incremental
            save:      {includeText: false},
          },
        },
        serverInfo: {name: "clear-ls", version: VERSION},
      }
    end

    # -- text sync ----------------------------------------------------------

    private def did_open(params : JSON::Any) : Nil
      doc = params["textDocument"]
      state = @vfs.open(doc["uri"].as_s, doc["text"].as_s, doc["version"].as_i64)
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
      Log.debug do
        ranges = state.tree.changed_ranges.try(&.join(", ")) || "full"
        "didChange #{state.uri} v#{state.version}: #{changes.size} edit(s), changed [#{ranges}], error=#{state.tree.has_error?}"
      end
    end

    private def did_close(params : JSON::Any) : Nil
      @vfs.close(params["textDocument"]["uri"].as_s)
    end

    private def did_change_watched(params : JSON::Any) : Nil
      params["changes"].as_a.each { |c| @vfs.disk_changed(c["uri"].as_s) }
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
