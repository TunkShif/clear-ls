require "./spec_helper"

include ClearLS

private def lc(l, c)
  LineCol.new(l.to_u32, c.to_u32)
end

private def with_tmp(& : String ->)
  dir = File.tempname("clear-ls-vfs")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

require "file_utils"

describe VFS do
  it "interns normalised URIs to stable ids" do
    vfs = VFS.new
    a = vfs.id_for("file:///tmp/x/../a.cr")
    vfs.id_for("file:///tmp/a.cr").should eq a
    vfs.id_for("file:///tmp/b.cr").should_not eq a
    vfs.uri(a).should eq "file:///tmp/a.cr"
  end

  it "decodes and re-encodes percent-escaped paths" do
    VFS.normalize_uri("file:///tmp/my%20dir/a.cr").should eq "file:///tmp/my%20dir/a.cr"
    VFS.path_for("file:///tmp/my%20dir/a.cr").should eq "/tmp/my dir/a.cr"
    VFS.normalize_uri("untitled:Untitled-1").should eq "untitled:Untitled-1"
  end

  it "applies incremental changes in order" do
    vfs = VFS.new
    vfs.open("file:///a.cr", "a = 1\n", 1)
    state = vfs.change("file:///a.cr", 2, [
      {lc(0, 5), lc(0, 5), "\nb = 😀"},
      # Second edit is relative to the text after the first one.
      {lc(1, 4), lc(1, 6), "2"},
    ], PositionEncoding::UTF16)
    state.text.should eq "a = 1\nb = 2\n"
    state.version.should eq 2
    state.tree.root.sexp.should eq Syntax::Parser.new.parse(state.text).root.sexp
  end

  it "handles full-text replacement in a change batch" do
    vfs = VFS.new
    vfs.open("file:///a.cr", "x", 1)
    state = vfs.change("file:///a.cr", 2, [
      {lc(0, 0), lc(0, 1), "y"},
      {nil, nil, "z = 1"},
      {lc(0, 0), lc(0, 1), "w"},
    ], PositionEncoding::UTF16)
    state.text.should eq "w = 1"
  end

  it "keeps snapshots immutable across edits" do
    vfs = VFS.new
    vfs.open("file:///a.cr", "one", 1)
    snap = vfs.snapshot
    vfs.snapshot.should be(snap)
    vfs.change("file:///a.cr", 2, [{nil, nil, "two"}], PositionEncoding::UTF16)
    snap.file?("file:///a.cr").not_nil!.text.should eq "one"
    vfs.snapshot.file?("file:///a.cr").not_nil!.text.should eq "two"
    vfs.snapshot.generation.should be > snap.generation
  end

  it "prefers overlays over disk and falls back on close" do
    with_tmp do |dir|
      path = File.join(dir, "a.cr")
      File.write(path, "disk")
      uri = VFS.uri_for(path)
      vfs = VFS.new

      vfs.load(uri).not_nil!.text.should eq "disk"
      vfs.open(uri, "buffer", 1)
      vfs.file?(uri).not_nil!.text.should eq "buffer"

      File.write(path, "disk2")
      vfs.disk_changed(uri)
      vfs.file?(uri).not_nil!.text.should eq "buffer"

      vfs.close(uri)
      vfs.open?(uri).should be_false
      vfs.file?(uri).not_nil!.text.should eq "disk2"
    end
  end

  it "forgets closed buffers that have no disk file" do
    vfs = VFS.new
    vfs.open("untitled:1", "x", 1)
    vfs.close("untitled:1")
    vfs.file?("untitled:1").should be_nil
  end

  it "bumps revision on every content change" do
    vfs = VFS.new
    r1 = vfs.open("file:///a.cr", "a", 1).revision
    r2 = vfs.change("file:///a.cr", 2, [{nil, nil, "b"}], PositionEncoding::UTF16).revision
    r2.should be > r1
  end
end
