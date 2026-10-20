require "../spec_helper"
require "file_utils"

include ClearLS
include ClearLS::Workspace

private def with_project(files : Hash(String, String), &)
  root = File.tempname("clear-ls-ws")
  files.each do |path, text|
    full = File.join(root, path)
    Dir.mkdir_p(File.dirname(full))
    File.write(full, text)
  end
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def project(root : String) : Project
  # No stdlib: keeps specs fast and independent of the installed compiler.
  Project.new(root, ["lib"], nil, nil, "x86_64-unknown-linux-gnu")
end

describe RequireResolver do
  it "resolves like the compiler's CrystalPath" do
    with_project({
      "src/app.cr"                  => "",
      "src/app/models/user.cr"      => "",
      "src/app/models/nested/x.cr"  => "",
      "src/helper.cr"               => "",
      "src/dir/dir.cr"              => "",
      "lib/kemal/src/kemal.cr"      => "",
      "lib/kemal/src/kemal/route.cr" => "",
      "lib/db/src/db/pool.cr"       => "",
    }) do |root|
      r = RequireResolver.new([File.join(root, "lib")])
      from = File.join(root, "src/app.cr")
      r.resolve("./helper", from).should eq [File.join(root, "src/helper.cr")]
      r.resolve("./helper.cr", from).should eq [File.join(root, "src/helper.cr")]
      r.resolve("./dir", from).should eq [File.join(root, "src/dir/dir.cr")]
      r.resolve("./app/models/*", from).should eq [File.join(root, "src/app/models/user.cr")]
      r.resolve("./app/models/**", from).should eq [
        File.join(root, "src/app/models/user.cr"), File.join(root, "src/app/models/nested/x.cr"),
      ]
      r.resolve("kemal", from).should eq [File.join(root, "lib/kemal/src/kemal.cr")]
      r.resolve("kemal/route", from).should eq [File.join(root, "lib/kemal/src/kemal/route.cr")]
      r.resolve("db/pool", from).should eq [File.join(root, "lib/db/src/db/pool.cr")]
      r.resolve("missing", from).should be_empty
      r.resolve("./missing", from).should be_empty
    end
  end
end

describe Index do
  it "indexes workspace files and their require closure" do
    with_project({
      "shard.yml"              => "name: app",
      "src/app.cr"             => %(require "dep"\nrequire "./app/*"\nmodule App; end),
      "src/app/user.cr"        => "class App::User < Dep::Base; end",
      "lib/dep/src/dep.cr"     => "module Dep\n  class Base\n    def save; end\n  end\nend",
      "lib/unused/src/unused.cr" => "class Unused; end",
    }) do |root|
      idx = Index.new(project(root), VFS.new)
      idx.load(workers: 1)
      map = idx.def_map
      user = map.lookup_path("App::User").not_nil!
      map.lookup_member(user, "save").size.should eq 1
      # Unrequired shards are not indexed.
      map.lookup_path("Unused").should be_nil
    end
  end

  it "loads in parallel with the same result" do
    files = {"src/a.cr" => %(require "./b/*")}
    20.times { |i| files["src/b/f#{i}.cr"] = "class C#{i}\n  def m#{i}; end\nend" }
    with_project(files) do |root|
      seq = Index.new(project(root), VFS.new).tap(&.load(workers: 1))
      par = Index.new(project(root), VFS.new).tap(&.load(workers: 4))
      par.size.should eq seq.size
      par.def_map.types.map(&.full_name).sort.should eq seq.def_map.types.map(&.full_name).sort
    end
  end

  it "does not rebuild the DefMap for body-only edits" do
    with_project({"src/a.cr" => "class A\n  def foo\n    1\n  end\nend\n"}) do |root|
      vfs = VFS.new
      idx = Index.new(project(root), vfs)
      idx.load(workers: 1)
      idx.def_map
      rebuilds = idx.rebuilds

      uri = VFS.uri_for(File.join(root, "src/a.cr"))
      state = vfs.open(uri, File.read(File.join(root, "src/a.cr")), 1)
      idx.update(state).should be_false
      body_edit = vfs.change(uri, 2, [{LineCol.new(2, 4), LineCol.new(2, 5), "x + 2"}], PositionEncoding::UTF16)
      idx.update(body_edit).should be_false
      idx.def_map
      idx.rebuilds.should eq rebuilds

      decl_edit = vfs.change(uri, 3, [{LineCol.new(1, 9), LineCol.new(1, 9), "(y)"}], PositionEncoding::UTF16)
      idx.update(decl_edit).should be_true
      idx.def_map
      idx.rebuilds.should eq rebuilds + 1
    end
  end

  it "picks up new requires from edited files" do
    with_project({"src/a.cr" => "", "src/b.cr" => "class FromB; end"}) do |root|
      vfs = VFS.new
      idx = Index.new(project(root), vfs)
      idx.load(workers: 1)
      size = idx.size
      uri = VFS.uri_for(File.join(root, "src/a.cr"))
      idx.update(vfs.open(uri, %(require "./b"), 1)).should be_true
      idx.size.should eq size
      idx.def_map.lookup_path("FromB").should_not be_nil
    end
  end
end
