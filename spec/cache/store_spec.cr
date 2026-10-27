require "../spec_helper"
require "file_utils"

include ClearLS

private def write_files(root : String, files : Hash(String, String)) : Nil
  files.each do |path, text|
    full = File.join(root, path)
    Dir.mkdir_p(File.dirname(full))
    File.write(full, text)
  end
end

private SHARDS_INFO = <<-YAML
  ---
  version: 1.0
  shards:
    dep:
      git: https://example.com/dep.git
      version: 1.2.3
    local:
      path: ../local
  YAML

# A fake stdlib, a project with one versioned shard and one path
# dependency, and a cache directory, all under one temp dir.
private def with_setup(&)
  base = File.tempname("clear-ls-store")
  stdlib = File.join(base, "stdlib")
  write_files(stdlib, {"prelude.cr" => %(require "./object"), "object.cr" => "class Object\n  def same; end\nend"})
  {"a", "b"}.each do |name|
    write_files(File.join(base, name), {
      "shard.yml"              => "name: #{name}\ntargets:\n  #{name}:\n    main: src/main.cr",
      "src/main.cr"            => %(require "dep"\nrequire "local"\nclass #{name.upcase}; end),
      "lib/.shards.info"       => SHARDS_INFO,
      "lib/dep/src/dep.cr"     => "module Dep\n  def self.hi; end\nend",
    })
    write_files(File.join(base, "local"), {"src/local.cr" => "module Local; end"})
    File.symlink(File.join(base, "local"), File.join(base, name, "lib/local"))
  end
  yield base, stdlib, File.join(base, "cache")
ensure
  FileUtils.rm_rf(base) if base
end

private def index(root : String, stdlib : String, cache : String) : Workspace::Index
  project = Workspace::Project.new(root, ["lib", stdlib], stdlib, "9.9.9", "x86_64-unknown-linux-gnu")
  idx = Workspace::Index.new(project, VFS.new)
  idx.store = Cache::Store.new(cache, stdlib, "9.9.9", root)
  idx.load(workers: 1)
  idx
end

private def types(idx) : Array(String)
  idx.def_map.types.map(&.full_name).sort
end

describe Cache::Store do
  it "lists versioned shards and skips path dependencies" do
    with_setup do |base, _, _|
      Cache::Store.shards(File.join(base, "a")).should eq({"dep" => "1.2.3"})
    end
  end

  it "shares stdlib and shard packs between projects" do
    with_setup do |base, stdlib, cache|
      a1 = index(File.join(base, "a"), stdlib, cache)
      a1.store.not_nil!.hits.should eq 0
      packs = Dir.children(File.join(cache, "packs")).sort
      packs.size.should eq 2
      packs.any?(&.starts_with?("stdlib-9.9.9-")).should be_true
      packs.should contain "shard-dep-1.2.3.pack"

      # Same project again, then a second project: stdlib and dep come
      # from the packs; project files and the path dependency don't.
      a2 = index(File.join(base, "a"), stdlib, cache)
      a2.store.not_nil!.hits.should eq 3
      a2.store.not_nil!.misses.should eq 0
      types(a2).should eq types(a1)
      b = index(File.join(base, "b"), stdlib, cache)
      b.store.not_nil!.hits.should eq 3
      types(b).should contain "Dep"
      types(b).should contain "Local"
    end
  end

  it "re-parses a patched shard file and keeps the shared entry" do
    with_setup do |base, stdlib, cache|
      index(File.join(base, "a"), stdlib, cache)
      File.write(File.join(base, "b/lib/dep/src/dep.cr"), "module Dep\n  def self.patched; end\nend")
      b = index(File.join(base, "b"), stdlib, cache)
      b.store.not_nil!.misses.should eq 1
      dep = b.def_map.lookup_path("Dep").not_nil!
      b.def_map.lookup_member(dep, "self.patched").size.should eq 1
      # Project a still gets the pristine entry.
      a = index(File.join(base, "a"), stdlib, cache)
      a.store.not_nil!.hits.should eq 3
      a.def_map.lookup_member(a.def_map.lookup_path("Dep").not_nil!, "self.hi").size.should eq 1
    end
  end

  it "adds newly required stdlib files to the pack" do
    with_setup do |base, stdlib, cache|
      index(File.join(base, "a"), stdlib, cache)
      File.write(File.join(stdlib, "json.cr"), "module JSON; end")
      File.write(File.join(base, "b/src/main.cr"), %(require "json"\nclass B; end))
      b = index(File.join(base, "b"), stdlib, cache)
      b.store.not_nil!.misses.should eq 1
      again = index(File.join(base, "b"), stdlib, cache)
      again.store.not_nil!.misses.should eq 0
      types(again).should contain "JSON"
    end
  end

  it "ignores packs of another Crystal version or a corrupt pack" do
    with_setup do |base, stdlib, cache|
      root = File.join(base, "a")
      index(root, stdlib, cache)
      other = Workspace::Index.new(Workspace::Project.new(root, ["lib", stdlib], stdlib, "10.0.0", "x86_64-unknown-linux-gnu"), VFS.new)
      other.store = Cache::Store.new(cache, stdlib, "10.0.0", root)
      other.load(workers: 1)
      other.store.not_nil!.hits.should eq 1 # the shard pack only

      Dir.glob(File.join(cache, "packs", "*.pack")).each { |p| File.write(p, "garbage") }
      idx = index(root, stdlib, cache)
      idx.store.not_nil!.hits.should eq 0
      types(idx).should contain "Dep"
    end
  end

  it "evicts packs unused for a month" do
    with_setup do |base, stdlib, cache|
      index(File.join(base, "a"), stdlib, cache)
      stale = File.join(cache, "packs", "shard-old-0.1.0.pack")
      File.write(stale, "x")
      File.touch(stale, Time.utc - 31.days)
      index(File.join(base, "a"), stdlib, cache)
      File.exists?(stale).should be_false
    end
  end
end
