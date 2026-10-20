require "uri"
require "./base/line_index"
require "./syntax"

module ClearLS
  # One file's text at one revision, plus its parse.
  #
  # Immutable. A request captures a `Snapshot` and uses only it, so concurrent
  # edits never change what that request observes.
  class FileState
    getter id : FileId
    getter uri : String
    # Monotonic per file; bumps on every content change.
    getter revision : UInt64
    # Client document version for open buffers; `nil` when read from disk.
    getter version : Int64?
    getter tree : Syntax::Tree

    def initialize(@id, @uri, @revision, @version, @tree)
    end

    def text : String
      @tree.text
    end

    def line_index : LineIndex
      @tree.line_index
    end

    def overlay? : Bool
      !@version.nil?
    end
  end

  # Immutable view of every known file at one moment.
  class Snapshot
    getter generation : UInt64

    def initialize(@generation : UInt64, @files : Hash(FileId, FileState), @ids : Hash(String, FileId))
    end

    def file(id : FileId) : FileState
      @files[id]
    end

    def file?(id : FileId) : FileState?
      @files[id]?
    end

    def file?(uri : String) : FileState?
      @ids[uri]?.try { |id| @files[id]? }
    end

    def files : Enumerable(FileState)
      @files.values
    end
  end

  # Virtual file system: interns URIs to `FileId`s and layers editor overlays
  # over disk contents.
  #
  # Open documents (overlays) always win over disk. Disk files are loaded
  # lazily through `#load` and refreshed by `#disk_changed`. Each mutation
  # produces a new `Snapshot` cheaply: unchanged `FileState`s and their trees
  # are shared, not copied.
  #
  # Not thread-safe; mutate from one fiber (the server main loop).
  class VFS
    @ids = {} of String => FileId
    @uris = [] of String
    @files = {} of FileId => FileState
    @disk = {} of FileId => FileState
    @generation = 0_u64
    @revisions = Hash(FileId, UInt64).new(0_u64)
    @snapshot : Snapshot? = nil
    @parser = Syntax::Parser.new
    # Line indexes for files that are not loaded (location conversion only).
    @line_indexes = {} of FileId => LineIndex

    # Interns *uri*. Normalised so `file:///a/../b.cr` and `file:///b.cr` match.
    def id_for(uri : String) : FileId
      key = VFS.normalize_uri(uri)
      @ids[key] ||= begin
        @uris << key
        FileId.new((@uris.size - 1).to_u32)
      end
    end

    def uri(id : FileId) : String
      @uris[id.value]
    end

    # Current state of a file, or `nil` if neither open nor loaded.
    def file?(uri : String) : FileState?
      @ids[VFS.normalize_uri(uri)]?.try { |id| @files[id]? }
    end

    def open?(uri : String) : Bool
      file?(uri).try(&.overlay?) || false
    end

    # textDocument/didOpen: start tracking the editor buffer.
    def open(uri : String, text : String, version : Int64) : FileState
      id = id_for(uri)
      store(id, @parser.parse(text), version)
    end

    # textDocument/didChange. Edits apply in order, each against the text left
    # by the previous one. `nil` range means full replacement.
    def change(uri : String, version : Int64, changes : Enumerable({LineCol?, LineCol?, String}), encoding : PositionEncoding) : FileState
      id = id_for(uri)
      state = @files[id]? || raise ArgumentError.new("didChange for unopened document #{uri}")
      tree = state.tree
      text, index = tree.text, tree.line_index
      pending = [] of Syntax::TextEdit

      changes.each do |(start, stop, new_text)|
        if start && stop
          a = index.offset(start, encoding)
          b = Math.max(a, index.offset(stop, encoding))
          edit = Syntax::TextEdit.new(TextRange.new(a, b), new_text)
          pending << edit
          text = edit.apply(text)
        else
          # Full replacement discards earlier edits in this batch.
          pending.clear
          tree = @parser.parse(new_text)
          text = new_text
        end
        index = LineIndex.new(text)
      end
      tree = @parser.reparse(tree, pending) unless pending.empty?
      store(id, tree, version)
    end

    # textDocument/didClose: drop the overlay and fall back to disk.
    def close(uri : String) : Nil
      id = id_for(uri)
      return unless @files[id]?.try(&.overlay?)
      @files.delete(id)
      if disk = @disk[id]?
        @files[id] = disk
        bump
      else
        # The cache may be stale (changed while open) or never loaded.
        read_disk(id) || bump
      end
    end

    # Loads a file from disk unless it is open. Returns `nil` if unreadable.
    def load(uri : String) : FileState?
      id = id_for(uri)
      if state = @files[id]?
        return state
      end
      read_disk(id)
    end

    # Line index of a file without parsing it: the open/loaded state if any,
    # otherwise the text on disk (cached until `disk_changed`).
    def line_index_for(id : FileId) : LineIndex?
      if state = @files[id]?
        return state.line_index
      end
      @line_indexes[id] ||= begin
        path = VFS.path_for(uri(id)) || return nil
        return nil unless File.file?(path)
        LineIndex.new(File.read(path))
      end
    rescue IO::Error
      nil
    end

    # The file changed on disk (watcher or save). Ignored while open.
    def disk_changed(uri : String) : Nil
      id = id_for(uri)
      @disk.delete(id)
      @line_indexes.delete(id)
      if @files[id]?.try(&.overlay?)
        return
      end
      @files.delete(id)
      read_disk(id)
      bump
    end

    def snapshot : Snapshot
      @snapshot ||= Snapshot.new(@generation, @files.dup, @ids.dup)
    end

    def self.normalize_uri(uri : String) : String
      parsed = URI.parse(uri)
      return uri unless parsed.scheme == "file"
      path = Path.posix(URI.decode(parsed.path)).normalize.to_s
      URI.new(scheme: "file", host: parsed.host || "", path: URI.encode_path(path)).to_s
    rescue URI::Error
      uri
    end

    def self.path_for(uri : String) : String?
      parsed = URI.parse(uri)
      URI.decode(parsed.path) if parsed.scheme == "file"
    rescue URI::Error
      nil
    end

    def self.uri_for(path : String | Path) : String
      URI.new(scheme: "file", host: "", path: URI.encode_path(Path[path].expand.to_s)).to_s
    end

    private def read_disk(id : FileId) : FileState?
      path = VFS.path_for(uri(id))
      return nil unless path && File.file?(path)
      text = File.read(path)
      state = FileState.new(id, uri(id), next_revision(id), nil, @parser.parse(text))
      @disk[id] = state
      @files[id] = state
      bump
      state
    rescue IO::Error
      nil
    end

    private def store(id : FileId, tree : Syntax::Tree, version : Int64) : FileState
      state = FileState.new(id, uri(id), next_revision(id), version, tree)
      @files[id] = state
      bump
      state
    end

    private def next_revision(id : FileId) : UInt64
      @revisions[id] += 1
    end

    private def bump : Nil
      @generation += 1
      @snapshot = nil
    end
  end
end
