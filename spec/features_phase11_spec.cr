require "./spec_helper"
require "./support/feature_client"
require "./support/prelude"

# Persistent cache through the server: a second session over the same
# project reads item trees, word sets and compiler facts from the cache.

private def session(root, files, cache_dir, compiler = {enabled: false}, enabled = true, &)
  c = FeatureClient.new(files, PRELUDE_FILES, compiler, cache: {enabled: enabled, dir: cache_dir}, root: root)
  yield c
ensure
  c.try(&.cleanup(keep: true))
end

private FILES = {
  "shard.yml"     => "name: app\ntargets:\n  app:\n    main: src/app.cr\n",
  "src/app.cr"    => %(require "./model"\nm = Model.new\nm.name\n),
  "src/model.cr"  => "class Model\n  def name : String\n    \"m\"\n  end\nend\n",
}

private def with_dirs(&)
  root = File.tempname("clear-ls-p11")
  cache = File.tempname("clear-ls-p11-cache")
  yield root, cache
ensure
  FileUtils.rm_rf(root) if root
  FileUtils.rm_rf(cache) if cache
end

describe "persistent cache" do
  it "serves a second session from the cache, ignored by git" do
    with_dirs do |root, cache|
      session(root, FILES, cache) do |c|
        c.server.index.local.not_nil!.hits.should eq 0
        c.server.index.store.not_nil!.misses.should be > 0
      end
      File.read(File.join(root, ".clear-ls/.gitignore")).should eq "*\n"
      session(root, FILES, cache) do |c|
        idx = c.server.index
        idx.local.not_nil!.hits.should eq 2
        idx.local.not_nil!.misses.should eq 0
        idx.store.not_nil!.misses.should eq 0
        # Word sets came from the cache: the reference search finds the use.
        u = c.open("src/model.cr")
        refs = c.request("textDocument/references", {textDocument: {uri: u}, position: c.pos("src/model.cr", "name"), context: {includeDeclaration: false}})
        refs.as_a.map(&.["uri"].as_s).should eq [c.uri("src/app.cr")]
      end
    end
  end

  it "re-reads edited and new files, drops deleted ones" do
    with_dirs do |root, cache|
      session(root, FILES, cache) { }
      model = File.join(root, "src/model.cr")
      File.write(model, "class Model\n  def title : String\n    \"t\"\n  end\nend\n")
      File.write(File.join(root, "src/extra.cr"), "class Extra; end")
      session(root, FILES.reject("src/model.cr"), cache) do |c|
        local = c.server.index.local.not_nil!
        local.misses.should eq 2 # model.cr edited, extra.cr new
        map = c.server.index.def_map
        map.lookup_member(map.lookup_path("Model").not_nil!, "title").size.should eq 1
      end
      File.delete(File.join(root, "src/extra.cr"))
      session(root, FILES.reject("src/model.cr"), cache) do |c|
        c.server.index.def_map.lookup_path("Extra").should be_nil
        c.server.index.local.not_nil!.misses.should eq 0
      end
      Cache::Pack.read(File.join(root, ".clear-ls/cache/items.pack")).files.keys.none?(&.ends_with?("extra.cr")).should be_true
    end
  end

  it "ignores a corrupt pack and a pack of another build" do
    with_dirs do |root, cache|
      session(root, FILES, cache) { }
      pack = File.join(root, ".clear-ls/cache/items.pack")
      File.write(pack, "junk")
      session(root, FILES, cache) do |c|
        c.server.index.local.not_nil!.hits.should eq 0
        c.server.index.def_map.lookup_path("Model").should_not be_nil
      end
      # Rewritten; now pretend it came from another clear-ls version.
      bytes = File.read(pack).to_slice
      key = Cache.build_key.to_slice
      at = (0..bytes.size - key.size).find { |i| bytes[i, key.size] == key }.not_nil!
      tampered = bytes.dup
      tampered[at] = 'X'.ord.to_u8
      body = tampered[0, tampered.size - 8]
      IO::ByteFormat::LittleEndian.encode(StableHash.hash(body), tampered[tampered.size - 8, 8])
      File.write(pack, tampered)
      session(root, FILES, cache) do |c|
        c.server.index.local.not_nil!.hits.should eq 0
      end
    end
  end

  it "neither reads nor writes when disabled" do
    with_dirs do |root, cache|
      session(root, FILES, cache, enabled: false) do |c|
        c.server.index.local.should be_nil
      end
      Dir.exists?(File.join(root, ".clear-ls")).should be_false
      Dir.exists?(cache).should be_false
    end
  end

  it "clearLs/clearCache drops both layers and re-indexes" do
    with_dirs do |root, cache|
      session(root, FILES, cache) { }
      session(root, FILES, cache) do |c|
        c.server.index.local.not_nil!.hits.should eq 2
        r = c.request("clearLs/clearCache")
        r["cleared"].as_bool.should be_true
        c.server.index.local.not_nil!.hits.should eq 0
        c.server.index.store.not_nil!.hits.should eq 0
        c.server.index.def_map.lookup_path("Model").should_not be_nil
      end
    end
  end

  it "applies the previous session's compiler facts before the first check" do
    files = {
      "shard.yml"  => "name: x\ntargets:\n  x:\n    main: src/x.cr\n",
      "src/x.cr"   => "class Crate\n  {% for n in %w(width) %}\n    def {{n.id}} : Int32; 1; end\n  {% end %}\nend\nb = Crate.new\nw = b.width\n",
    }
    with_dirs do |root, cache|
      session(root, files, cache, compiler: {enabled: true, debounceMs: 0}) do |c|
        c.wait_compiler
        c.server.index.facts.methods.should_not be_empty
      end
      # Compiler on, but nothing checked yet: facts come from the cache.
      session(root, files, cache, compiler: {enabled: true, debounceMs: 60_000}) do |c|
        c.server.index.facts.methods.map(&.header).should contain "width() : Int32"
        u = c.open("src/x.cr")
        hover = c.request("textDocument/hover", {textDocument: {uri: u}, position: c.pos("src/x.cr", "w = b")})
        hover["contents"]["value"].as_s.should contain "Int32"
      end
    end
  end
end
