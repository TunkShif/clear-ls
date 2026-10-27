require "../spec_helper"
require "file_utils"
require "../../src/clear_ls/cache/pack"

include ClearLS

# Deep structural equality over every instance variable, so a field added
# to an item record but forgotten in the codec fails here.
private def same!(a, b, path = "") : Nil
  case a
  when Array
    b = b.as(Array)
    fail "#{path}: size #{a.size} != #{b.size}" unless a.size == b.size
    a.each_with_index { |x, i| same!(x, b[i], "#{path}[#{i}]") }
  when Items::Item, Items::ItemTree, Items::Cond, Items::Param, Items::Signature,
       Items::TypeHeader, Items::Require, Items::TopLevelMixin
    fail "#{path}: #{a.class} != #{b.class}" unless a.class == b.class
    same_ivars!(a, b, path)
  else
    fail "#{path}: #{a.inspect} != #{b.inspect}" unless a == b
  end
end

private def same_ivars!(a : T, b, path) : Nil forall T
  b = b.as(T)
  {% for ivar in T.instance_vars %}
    same!(a.@{{ ivar.id }}, b.@{{ ivar.id }}, "#{path}.{{ ivar.id }}")
  {% end %}
end

private def lower(text : String) : Items::ItemTree
  Items::Lower.lower(Syntax::Parser.new.parse(text))
end

private def round_trip(trees : Hash(String, Items::ItemTree)) : Cache::Pack
  w = Cache::Writer.new(Cache::PackKind::Local, "test")
  trees.each { |path, t| w.add(Cache::FileMeta.new(path, 1_i64, 2_i64, 3_u64)) { |p| p.tree(t) } }
  Cache::Pack.new(w.to_slice)
end

SAMPLE = <<-CR
  require "./a"
  {% if flag?(:linux) && !flag?(:musl) || flag?(:darwin) %}
    require "./linux"
  {% end %}
  include Foo
  extend Bar

  # Docs.
  @[Flags]
  enum E : UInt8
    A = 1
    B
  end

  module Outer::Inner(T, *U)
    abstract class Base < Parent(T)
      include Comparable(Base)
      extend Helpers
      getter x : Int32 = 1
      property! y : String?
      record Point, a : Int32, b = 2

      def initialize(@z : Int32 = 3); end

      private def self.f(a, ext int : Int32 = 1, *rest, k : String, **opts, &block : -> Nil) : Nil forall X
      end

      abstract def g : String
      protected macro m(x); end
      {% if compare_versions(Crystal::VERSION, "1.0.0") > 0 %}
        def newer; end
      {% end %}
    end
  end

  lib LibC
    alias Int = Int32
    type Handle = Void*
    struct S
      x : Int32
    end
    union U
      y : Int64
    end
    $errno : Int
    fun printf(fmt : UInt8*, ...) : Int32
    fun c_name = real_name(Int32) : Void
  end

  class Broken
    def ok; end
    def bad(
  CR

describe Cache do
  it "round-trips every field of an item tree" do
    tree = lower(SAMPLE)
    pack = round_trip({"/x/a.cr" => tree})
    back = pack.payload("/x/a.cr").not_nil!.tree
    same!(tree, back)
    back.fingerprint.should eq tree.fingerprint
    pack.meta?("/x/a.cr").should eq Cache::FileMeta.new("/x/a.cr", 1_i64, 2_i64, 3_u64)
    pack.payload("/x/missing.cr").should be_nil
  end

  it "round-trips the indexed stdlib and this repository" do
    root = File.expand_path("../..", __DIR__)
    project = Workspace::Project.detect(root)
    idx = Workspace::Index.new(project, VFS.new)
    idx.load
    trees = {} of String => Items::ItemTree
    idx.each_entry { |_, e| trees[e.path] = e.items }
    trees.size.should be > 100
    pack = round_trip(trees)
    trees.each do |path, t|
      back = pack.payload(path).not_nil!.tree
      back.fingerprint.should eq t.fingerprint
      same!(t, back, path)
    end
  end

  it "rejects corrupt, truncated and foreign packs" do
    bytes = Cache::Writer.new(Cache::PackKind::Stdlib, "k").tap do |w|
      w.add(Cache::FileMeta.new("/a.cr", 0_i64, 0_i64, 0_u64)) { |p| p.tree(lower("class A; end")) }
    end.to_slice
    Cache::Pack.new(bytes).kind.should eq Cache::PackKind::Stdlib

    flipped = bytes.dup
    flipped[flipped.size // 2] ^= 0xff_u8
    expect_raises(Cache::FormatError) { Cache::Pack.new(flipped) }
    expect_raises(Cache::FormatError) { Cache::Pack.new(bytes[0, bytes.size - 3]) }
    expect_raises(Cache::FormatError) { Cache::Pack.new(Bytes.new(0)) }
    expect_raises(Cache::FormatError) { Cache::Pack.new("not a pack at all, really".to_slice) }
  end

  it "writes atomically" do
    dir = File.tempname("clear-ls-pack")
    path = File.join(dir, "p.pack")
    w = Cache::Writer.new(Cache::PackKind::Local, "k")
    w.write(path)
    Cache::Pack.read(path).key.should eq "k"
    Dir.children(dir).should eq ["p.pack"]
    expect_raises(Cache::FormatError) { Cache::Pack.read(File.join(dir, "missing")) }
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
