# Hovers the first byte of every named leaf token of FILE through a real
# `LSP::Server`; prints tokens without hover, grouped by CST kind.
#
#   bin/probes/hover_probe ROOT FILE
#
# ENV: ALL=1 lists every miss, SHOW=1 prints the hovers that worked.
require "../../src/clear_ls"
include ClearLS
proj = Workspace::Project.detect(ARGV[0])
::Log.setup(:error)
srv_out = IO::Memory.new
server = LSP::Server.new(LSP::Transport.new(IO::Memory.new, srv_out))
def msg(h) ; b = h.to_json; "Content-Length: #{b.bytesize}\r\n\r\n#{b}"; end
path = ARGV[1]
text = File.read(path)
uri = VFS.uri_for(path)
input = String.build do |io|
  io << msg({jsonrpc: "2.0", id: 0, method: "initialize", params: {rootUri: VFS.uri_for(ARGV[0]), capabilities: {general: {positionEncodings: ["utf-8"]}}}})
  io << msg({jsonrpc: "2.0", method: "initialized", params: {} of String => String})
  io << msg({jsonrpc: "2.0", method: "textDocument/didOpen", params: {textDocument: {uri: uri, languageId: "crystal", version: 1, text: text}}})
end
tree = Syntax::Parser.new.parse(text)
probes = [] of {Syntax::Node, Int32, Int32}
tree.root.walk do |n|
  if n.named? && n.named_child_count == 0 && !n.kind.comment? && !n.kind.literal_content?
    pt = tree.line_index.position(n.start_byte, PositionEncoding::UTF8)
    probes << {n, pt.line.to_i32, pt.column.to_i32}
  end
  true
end
inp = String.build do |io|
  io << input
  probes.each_with_index do |(n, l, c), i|
    io << msg({jsonrpc: "2.0", id: i + 1, method: "textDocument/hover", params: {textDocument: {uri: uri}, position: {line: l, character: c}}})
  end
end
server = LSP::Server.new(LSP::Transport.new(IO::Memory.new(inp), srv_out))
server.run
t = LSP::Transport.new(IO::Memory.new(srv_out.to_s), IO::Memory.new)
results = {} of Int64 => JSON::Any
while body = t.read
  j = JSON.parse(body)
  if id = j["id"]?.try(&.as_i64?)
    results[id] = j["result"]? || JSON::Any.new(nil)
  end
end
missing = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }
shown = [] of String
probes.each_with_index do |(n, l, c), i|
  r = results[(i + 1).to_i64]?
  label = "#{l + 1}:#{c + 1} #{n.text}"
  if r.nil? || r.raw.nil?
    missing["#{n.parent.try(&.kind)}/#{n.kind}"] << label
  else
    v = r["contents"]["value"].as_s.lines.reject(&.starts_with?("```")).first?.to_s
    shown << "#{label} => #{v[0, 70]}" if ENV["SHOW"]?
  end
end
shown.each { |s| puts s }
missing.to_a.sort_by { |(k, v)| -v.size }.each { |k, v| puts "#{k} (#{v.size}): #{(ENV["ALL"]? ? v : v.first(8)).join(" | ")}" }
