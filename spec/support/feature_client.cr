require "../spec_helper"
require "file_utils"

include ClearLS
include ClearLS::LSP

class FeatureClient
  getter server : Server
  @out = IO::Memory.new
  @next_id = 0
  getter root : String

  # *stdlib*: files placed in a fake stdlib dir with a prelude.cr that
  # requires them all.
  # *compiler*: `initializationOptions.compiler`; the real compiler is off
  # unless a spec asks for it.
  # *cache*: `initializationOptions.cache` (off unless given). *root*:
  # reuse a project directory (a second session over the same files).
  def initialize(files : Hash(String, String), stdlib : Hash(String, String)? = nil, compiler = {enabled: false}, workspace_caps = {} of String => String, references = {includePossible: false}, budgets = {} of String => Float64,
                 cache = {enabled: false}, root : String? = nil, warmup = {enabled: false}, crystal_version : String? = nil,
                 text_document_caps = {} of String => String, real_stdlib = false)
    @root = root || File.tempname("clear-ls-feat")
    files.each do |path, text|
      full = File.join(@root, path)
      Dir.mkdir_p(File.dirname(full))
      # Unchanged files keep their mtime (cache specs reuse *root*).
      write_if_changed(full, text)
    end
    @server = Server.new(Transport.new(IO::Memory.new, @out))
    std_dir = nil
    if stdlib
      std_dir = File.join(@root, ".stdlib")
      Dir.mkdir_p(std_dir)
      stdlib.each { |path, text| write_if_changed(File.join(std_dir, path), text) }
      write_if_changed(File.join(std_dir, "prelude.cr"), stdlib.keys.map { |k| %(require "./#{k.rchop(".cr")}") }.join('\n'))
    end
    paths = ["lib"] + (std_dir ? [std_dir] : [] of String)
    @server.project_factory = if real_stdlib
                                ->(root : String) { Workspace::Project.detect(root) }
                              else
                                ->(root : String) { Workspace::Project.new(root, paths, std_dir, crystal_version, "x86_64-unknown-linux-gnu") }
                              end
    @server.index_workers = 1
    # Specs opt in per session (`cache:` / `warmup:` options).
    @server.cache_allowed = true
    @server.warmup_allowed = true
    request("initialize", {rootUri: VFS.uri_for(@root), capabilities: {general: {positionEncodings: ["utf-16"]}, workspace: workspace_caps, textDocument: text_document_caps}, initializationOptions: {compiler: compiler, references: references, budgets: budgets, cache: cache, warmup: warmup}})
    notify("initialized", {} of String => String)
  end

  private def write_if_changed(path : String, text : String) : Nil
    File.write(path, text) unless File.file?(path) && File.read(path) == text
  end

  def cleanup(keep = false)
    request("shutdown") rescue nil
    FileUtils.rm_rf(@root) unless keep
  end

  def uri(path : String) : String
    VFS.uri_for(File.join(@root, path))
  end

  def open(path : String) : String
    u = uri(path)
    notify("textDocument/didOpen", {textDocument: {uri: u, languageId: "crystal", version: 1, text: File.read(File.join(@root, path))}})
    u
  end

  def request(method : String, params = nil) : JSON::Any
    @next_id += 1
    @server.dispatch({jsonrpc: "2.0", id: @next_id, method: method, params: params}.to_json)
    reply = response(@next_id)
    if reply.raw.nil? # answered later from another fiber
      deadline = Time.instant + 30.seconds
      while (reply = response(@next_id)).raw.nil?
        raise "#{method}: no response" if Time.instant > deadline
        sleep 10.milliseconds
      end
    end
    raise "#{method}: #{reply["error"]}" if reply["error"]?
    reply["result"]
  end

  # Sends a request without waiting (for jobs); returns the id.
  def send_request(method : String, params = nil) : Int32
    @next_id += 1
    @server.dispatch({jsonrpc: "2.0", id: @next_id, method: method, params: params}.to_json)
    @next_id
  end

  # Response (result or error object) of request *id*, waiting for it.
  def response_of(id : Int32, timeout = 30.seconds) : JSON::Any
    deadline = Time.instant + timeout
    while (reply = response(id)).raw.nil?
      raise "request #{id}: no response" if Time.instant > deadline
      sleep 1.millisecond
    end
    reply
  end

  def notify(method : String, params = nil) : Nil
    @server.dispatch({jsonrpc: "2.0", method: method, params: params}.to_json)
  end

  # Position of the first occurrence of *needle* (plus *shift* chars) in *path*.
  def pos(path : String, needle : String, shift = 0)
    text = File.read(File.join(@root, path))
    off = text.index!(needle) + shift
    before = text[0, off]
    line = before.count('\n')
    col = off - (before.rindex('\n').try(&.+(1)) || 0)
    {line: line, character: col}
  end

  # Server-initiated notifications with *method*, oldest first.
  def notifications(method : String) : Array(JSON::Any)
    server_messages(method).map(&.["params"])
  end

  # Server-initiated messages (notifications and requests) with *method*.
  def server_messages(method : String) : Array(JSON::Any)
    t = Transport.new(IO::Memory.new(@out.to_s), IO::Memory.new)
    found = [] of JSON::Any
    while body = t.read
      msg = JSON.parse(body)
      found << msg if msg["method"]? == method
    end
    found
  end

  # Waits for background compiler runs to finish.
  def wait_compiler(timeout = 30.seconds) : Nil
    deadline = Time.instant + timeout
    sleep 10.milliseconds
    while @server.checker.try(&.busy?)
      raise "compiler still busy" if Time.instant > deadline
      sleep 10.milliseconds
    end
  end

  # Latest diagnostics published for *path*.
  def diagnostics(path : String) : Array(JSON::Any)?
    u = uri(path)
    notifications("textDocument/publishDiagnostics").reverse.find { |n| n["uri"] == u }.try(&.["diagnostics"].as_a)
  end

  private def response(id : Int32) : JSON::Any
    t = Transport.new(IO::Memory.new(@out.to_s), IO::Memory.new)
    result = JSON::Any.new(nil)
    while body = t.read
      msg = JSON.parse(body)
      result = msg if msg["id"]? == id
    end
    result
  end
end

def with_client(files, stdlib = nil, compiler = {enabled: false}, workspace_caps = {} of String => String, references = {includePossible: false}, budgets = {} of String => Float64, &)
  c = FeatureClient.new(files, stdlib, compiler, workspace_caps, references, budgets)
  yield c
ensure
  c.try(&.cleanup)
end

