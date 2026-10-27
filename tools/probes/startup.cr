# Where startup time goes: project detection, `Index#load` split into
# source walk / work-queue indexing (parse, lower, require resolution,
# word sets) / malloc_trim, then the project DefMap build.
#
#   bin/probes/startup ROOT [RUNS]     e.g. bin/probes/startup tools/external/marten 3
#
# `WORKERS=n` overrides the worker count. Each run uses a fresh index.
require "../../src/clear_ls"

root = File.expand_path(ARGV[0]? || Dir.current)
runs = (ARGV[1]? || "1").to_i
workers = ENV["WORKERS"]?.try(&.to_i)
ms = ->(s : Time::Span) { s.total_milliseconds.round(1) }
runs.times do |i|
  project = nil
  detect = Time.measure { project = ClearLS::Workspace::Project.detect(root) }
  idx = ClearLS::Workspace::Index.new(project.not_nil!, ClearLS::VFS.new)
  workers ? idx.load(workers) : idx.load
  map = Time.measure { idx.def_map }
  s = idx.load_stats
  puts "run #{i + 1}: files=#{idx.size} detect=#{ms.call(detect)} load=#{ms.call(s.total)} " \
       "(walk=#{ms.call(s.walk)} index=#{ms.call(s.index)} trim=#{ms.call(s.trim)}) " \
       "def_map=#{ms.call(map)} total=#{ms.call(detect + s.total + map)}ms"
end
