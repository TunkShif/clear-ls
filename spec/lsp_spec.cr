require "./spec_helper"

include ClearLS
include ClearLS::LSP

# Scripted LSP client over in-memory pipes.
private class Client
  getter server : Server
  @out = IO::Memory.new
  @next_id = 0

  def initialize
    @server = Server.new(Transport.new(IO::Memory.new, @out))
    # Empty project, no stdlib: keeps lifecycle specs fast.
    @server.project_factory = ->(root : String) { Workspace::Project.new(File.tempname, ["lib"], nil, nil, "x86_64-unknown-linux-gnu") }
    @server.index_workers = 1
  end

  def request(method : String, params = nil) : JSON::Any
    @next_id += 1
    send({jsonrpc: "2.0", id: @next_id, method: method, params: params})
    replies.last
  end

  def notify(method : String, params = nil) : Nil
    send({jsonrpc: "2.0", method: method, params: params})
  end

  def send(msg) : Nil
    @server.dispatch(msg.to_json)
  end

  # All messages the server wrote so far.
  def replies : Array(JSON::Any)
    transport = Transport.new(IO::Memory.new(@out.to_s), IO::Memory.new)
    result = [] of JSON::Any
    while body = transport.read
      result << JSON.parse(body)
    end
    result
  end
end

private def init(client, encodings = ["utf-16"])
  client.request("initialize", {capabilities: {general: {positionEncodings: encodings}}})
  client.notify("initialized", {} of String => String)
end

describe Transport do
  it "round-trips framed messages with multibyte bodies" do
    io = IO::Memory.new
    t = Transport.new(IO::Memory.new, io)
    t.write(%({"a":"中😀"}))
    t.write(%({"b":1}))
    r = Transport.new(IO::Memory.new(io.to_s), IO::Memory.new)
    r.read.should eq %({"a":"中😀"})
    r.read.should eq %({"b":1})
    r.read.should be_nil
  end

  it "accepts extra headers and case-insensitive names" do
    raw = "content-length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}"
    Transport.new(IO::Memory.new(raw), IO::Memory.new).read.should eq "{}"
  end
end

describe Server do
  it "rejects requests before initialize" do
    c = Client.new
    c.request("clearLs/syntaxTree", {textDocument: {uri: "file:///a.cr"}})["error"]["code"].should eq -32002
  end

  it "negotiates position encoding" do
    c = Client.new
    r = c.request("initialize", {capabilities: {general: {positionEncodings: ["utf-16", "utf-8"]}}})
    r["result"]["capabilities"]["positionEncoding"].should eq "utf-8"
    c.server.encoding.should eq PositionEncoding::UTF8

    c2 = Client.new
    r2 = c2.request("initialize", {capabilities: {} of String => String})
    r2["result"]["capabilities"]["positionEncoding"].should eq "utf-16"
    caps = r2["result"]["capabilities"]
    caps["textDocumentSync"]["change"].should eq 2
    %w(definitionProvider hoverProvider documentHighlightProvider referencesProvider documentSymbolProvider).each do |k|
      caps[k]?.should_not be_nil
    end
    caps["renameProvider"]["prepareProvider"].should eq true
    caps["semanticTokensProvider"]["legend"]["tokenTypes"].as_a.first.should eq "namespace"
  end

  it "tracks open documents through incremental changes" do
    c = Client.new
    init(c)
    uri = "file:///tmp/x.cr"
    c.notify("textDocument/didOpen", {textDocument: {uri: uri, languageId: "crystal", version: 1, text: "def a\nend\n"}})
    c.notify("textDocument/didChange", {
      textDocument:   {uri: uri, version: 2},
      contentChanges: [{range: {start: {line: 0, character: 5}, end: {line: 0, character: 5}}, text: "(😀x)"}],
    })
    # "😀" is two utf-16 units; insert after it.
    c.notify("textDocument/didChange", {
      textDocument:   {uri: uri, version: 3},
      contentChanges: [{range: {start: {line: 0, character: 6}, end: {line: 0, character: 9}}, text: "y"}],
    })
    c.server.vfs.file?(uri).not_nil!.text.should eq "def a(y)\nend\n"
    sexp = c.request("clearLs/syntaxTree", {textDocument: {uri: uri}})["result"].as_s
    sexp.should contain("param_list")

    c.notify("textDocument/didClose", {textDocument: {uri: uri}})
    c.server.vfs.open?(uri).should be_false
  end

  it "reports unknown methods and bad JSON" do
    c = Client.new
    init(c)
    c.request("textDocument/unknown")["error"]["code"].should eq -32601
    c.server.dispatch("{not json")
    c.replies.last["error"]["code"].should eq -32700
  end

  it "follows shutdown/exit" do
    c = Client.new
    init(c)
    c.request("shutdown")["result"].raw.should be_nil
    c.request("clearLs/syntaxTree")["error"]["code"].should eq -32600
    c.notify("exit")
    c.server.exit_code.should eq 0

    c2 = Client.new
    init(c2)
    c2.notify("exit")
    c2.server.exit_code.should eq 1
  end

  it "survives a failing notification" do
    c = Client.new
    init(c)
    c.notify("textDocument/didChange", {textDocument: {uri: "file:///nope.cr", version: 1}, contentChanges: [] of String})
    c.request("shutdown")["result"].raw.should be_nil
  end
end
