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
  def initialize(files : Hash(String, String), stdlib : Hash(String, String)? = nil)
    @root = File.tempname("clear-ls-feat")
    files.each do |path, text|
      full = File.join(@root, path)
      Dir.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
    @server = Server.new(Transport.new(IO::Memory.new, @out))
    std_dir = nil
    if stdlib
      std_dir = File.join(@root, ".stdlib")
      Dir.mkdir_p(std_dir)
      stdlib.each { |path, text| File.write(File.join(std_dir, path), text) }
      File.write(File.join(std_dir, "prelude.cr"), stdlib.keys.map { |k| %(require "./#{k.rchop(".cr")}") }.join('\n'))
    end
    paths = ["lib"] + (std_dir ? [std_dir] : [] of String)
    @server.project_factory = ->(root : String) { Workspace::Project.new(root, paths, std_dir, nil, "x86_64-unknown-linux-gnu") }
    @server.index_workers = 1
    request("initialize", {rootUri: VFS.uri_for(@root), capabilities: {general: {positionEncodings: ["utf-16"]}}})
    notify("initialized", {} of String => String)
  end

  def cleanup
    FileUtils.rm_rf(@root)
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
    reply = last
    raise "#{method}: #{reply["error"]}" if reply["error"]?
    reply["result"]
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

  private def last : JSON::Any
    t = Transport.new(IO::Memory.new(@out.to_s), IO::Memory.new)
    result = JSON::Any.new(nil)
    while body = t.read
      result = JSON.parse(body)
    end
    result
  end
end

def with_client(files, stdlib = nil, &)
  c = FeatureClient.new(files, stdlib)
  yield c
ensure
  c.try(&.cleanup)
end

