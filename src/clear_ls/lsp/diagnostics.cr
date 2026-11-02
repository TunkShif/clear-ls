require "./server"
require "../compiler"

module ClearLS::LSP
  # Compiler diagnostics (`crystal build --no-codegen`), published
  # asynchronously.
  #
  # Programs are checked when the index is ready (shard targets), when a
  # file is opened (the programs that require it, unless already checked),
  # and when a file is saved or changed on disk. The compiler reads files
  # from disk, so results describe saved contents; positions are converted
  # with the saved text.
  #
  # Every program is compiled in the directory of its project (the
  # nearest `shard.yml` above the entry point, else the workspace root
  # that holds it), so each project's `lib/` resolves. Entry points are
  # that project's shard targets (`compiler.entries` per workspace root);
  # compiler facts go to the index of the root that holds the entry.
  #
  # Settings `compiler.*` (settings.cr).
  class Server
    @checker : Compiler::Checker? = nil
    # By project directory.
    @toolchains = {} of String => Compiler::Toolchain
    @entry_points = {} of String => Compiler::EntryPoints
    # Entry points checked since the last change on disk.
    @checked = Set(String).new

    getter checker

    private def compiler_enabled? : Bool
      @settings.bool("compiler.enabled")
    end

    # The `crystal` executable, run in the current request's root (for
    # `tool format`, which reads no other file).
    def toolchain : Compiler::Toolchain
      toolchain_in(@indexes.empty? ? (@roots.first? || Dir.current) : index.project.root)
    end

    # The toolchain running in *dir*.
    def toolchain_in(dir : String) : Compiler::Toolchain
      @toolchains[dir] ||= begin
        crystal = @settings.string?("compiler.path") || ENV["CRYSTAL"]? || "crystal"
        Compiler::Toolchain.new(crystal, dir)
      end
    end

    # Directory a program at *path* is compiled in: the project above it
    # (a nested project is its own; an installed shard in `lib/` belongs
    # to the project that installed it), else the workspace root holding
    # it, else the primary root.
    def compile_dir(path : String) : String
      dir = Workspace::Project.find_root(path)
      while dir && File.basename(File.dirname(dir)) == "lib" && (outer = Workspace::Project.find_root(File.dirname(dir)))
        dir = outer
      end
      dir || owner_index(path).try(&.project.root) ||
        @indexes.first?.try(&.project.root) || @roots.first? || Dir.current
    end

    # Entry points of the project in *dir*: `compiler.entries` relative
    # to it, else its shard targets. The setting applies to the primary
    # root, and to other workspace roots where one of its files exists.
    private def entry_points(dir : String) : Compiler::EntryPoints
      @entry_points[dir] ||= begin
        entries = nil.as(Array(String)?)
        if (i = @roots.index(dir)) && (list = @settings.strings?("compiler.entries"))
          full = list.map { |e| File.expand_path(e, dir) }
          entries = full if i == 0 || full.any? { |e| File.file?(e) }
        end
        Compiler::EntryPoints.new(dir, entries)
      end
    end

    private def start_compiler : Nil
      return unless compiler_enabled?
      checker = Compiler::Checker.new(->(entry : String) { toolchain_in(compile_dir(entry)) },
        ->(file : String, problems : Array(Compiler::Problem)) { publish_problems(file, problems) })
      checker.debounce = @settings.int("compiler.debounceMs").milliseconds
      if @settings.bool("compiler.facts")
        checker.extra_sources_for = ->(entry : String) { [exporter_for(compile_dir(entry))] }
        checker.on_result = ->(entry : String, result : Compiler::Job::Result) { import_facts(entry, result) }
      end
      @checker = checker
      @indexes.each { |idx| check_root(idx) }
    end

    # Checks the programs of a newly indexed root.
    private def check_root(idx : Workspace::Index) : Nil
      check_entries(entry_points(idx.project.root).targets)
    end

    # A workspace root was removed: its programs' runs, results and
    # facts go, and diagnostics only it reported are cleared. Entries
    # are matched by compile directory under the root (its nested
    # projects too).
    private def forget_root(root : String) : Nil
      prefix = root.ends_with?('/') ? root : root + "/"
      # An entry may be named as the compiler or client named it (a real
      # path for a root added through a symlink).
      gone = ->(e : String) { c = canonical_path(e); c.starts_with?(prefix) && owner_index(c).nil? }
      @checker.try(&.forget { |e| gone.call(e) })
      @checked.reject! { |e| gone.call(e) }
      @entry_facts.reject! { |e, _| gone.call(e) }
      @entry_points.reject! { |d, _| d == root || d.starts_with?(prefix) }
      @contexts.reject! { |k, _| gone.call(k.file) }
    end

    private def stop_compiler : Nil
      @checker.try(&.stop)
      @exporter_files.each_value { |f| File.delete?(f) }
      @exporter_files.clear
    end

    # The facts exporter for programs compiled in *dir* (it keeps methods
    # under that directory), written on first use.
    private def exporter_for(dir : String) : String
      @exporter_files[dir] ||= begin
        path = File.join(Dir.tempdir, "clear-ls-facts-#{Process.pid}-#{@exporter_files.size}.cr")
        File.write(path, Compiler::Exporter.source(dir))
        path
      end
    end

    @exporter_files = {} of String => String
    # Facts per entry point; merged into the index of the entry's root.
    @entry_facts = {} of String => Workspace::CompilerFacts

    # Takes the facts from one check. A section that the compile did not
    # reach (an error stopped it first) keeps the entry's previous facts.
    private def import_facts(entry : String, result : Compiler::Job::Result) : Nil
      parsed = Compiler::Exporter::Facts.parse(result.stdout)
      old = @entry_facts[entry]?
      methods = parsed.methods || old.try(&.methods) || [] of Compiler::Exporter::MethodFact
      ivars = parsed.ivars || old.try(&.ivars) || [] of Compiler::Exporter::IvarFact
      @entry_facts[entry] = Workspace::CompilerFacts.snapshot(methods, ivars)
      idx = facts_index(entry)
      idx.try(&.local).try(&.write_facts(entry_facts_of(idx)))
      apply_entry_facts
    end

    # The index an entry point's facts belong to.
    private def facts_index(entry : String) : Workspace::Index?
      owner_index(entry) || @indexes.first?
    end

    private def entry_facts_of(idx : Workspace::Index?) : Hash(String, Workspace::CompilerFacts)
      @entry_facts.select { |e, _| facts_index(e).same?(idx) }
    end

    # Writes every index's facts to its local cache (after a cache clear).
    private def write_all_facts : Nil
      @indexes.each { |idx| idx.local.try(&.write_facts(entry_facts_of(idx))) }
    end

    # Facts of the previous session (local cache), applied before the
    # first check; each file's facts apply only while its text matches
    # the digest taken with them. The first check replaces them.
    private def restore_facts(only : Workspace::Index? = nil) : Nil
      return unless compiler_enabled? && @settings.bool("compiler.facts")
      restored = false
      (only ? [only] : @indexes).each do |idx|
        saved = idx.local.try(&.read_facts) || next
        saved.each { |e, f| (@entry_facts[e] = f) if facts_index(e).same?(idx) }
        restored = true unless saved.empty?
      end
      apply_entry_facts if restored
    end

    # Sets each index's facts to the merge of its entries' facts.
    private def apply_entry_facts : Nil
      changed = false
      @indexes.each do |idx|
        mine = entry_facts_of(idx)
        digests = {} of String => UInt64
        mine.each_value { |f| digests.merge!(f.digests) }
        merged = Workspace::CompilerFacts.new(
          mine.values.flat_map(&.methods).uniq,
          mine.values.flat_map(&.ivars).uniq, digests)
        next if idx.facts == merged
        idx.facts = merged
        changed = true
        Log.info { "compiler facts: #{merged.methods.size} methods, #{merged.ivars.size} ivars (#{idx.project.root})" }
      end
      # Hints and tokens computed before the facts may have been unknown.
      refresh_views if changed
    end

    @refresh_id = 0

    # Asks the client to re-request inlay hints and semantic tokens
    # (when it advertised support); their answers depend on the index.
    private def refresh_views(only : Array(String)? = nil) : Nil
      {"inlayHint" => "workspace/inlayHint/refresh", "semanticTokens" => "workspace/semanticTokens/refresh"}.each do |cap, method|
        next if only && !only.includes?(cap)
        next unless @client_capabilities.dig?("workspace", cap, "refreshSupport").try(&.as_bool?)
        @refresh_id += 1
        @transport.write(JsonRpc.request("clear-ls-refresh-#{@refresh_id}", method))
      end
    end

    # didOpen: check the programs containing *uri* once. Programs checked
    # already are not rerun, but their last problems for the file are
    # published again: clients drop a document's diagnostics on close
    # (Neovim's `:e` is didClose + didOpen).
    private def compiler_opened(uri : String) : Nil
      entries = entries_for(uri) || return
      fresh = entries.reject { |e| @checked.includes?(e) }
      check_entries(fresh)
      if fresh.size < entries.size && (checker = @checker) && (path = VFS.path_for(uri))
        problems = checker.problems(path)
        publish_problems(path, problems) unless problems.empty?
      end
    end

    # didSave / disk change of *uri*: everything checked before is stale.
    private def compiler_saved(uri : String) : Nil
      # Failed context runs (e.g. the program did not compile) may succeed now.
      @contexts.reject! { |_, v| v.nil? }
      entries = entries_for(uri) || return
      @checked.clear
      check_entries(entries)
    end

    private def check_entries(entries : Array(String)) : Nil
      checker = @checker || return
      return if entries.empty?
      @checked.concat(entries)
      checker.check(entries)
    end

    private def entries_for(uri : String) : Array(String)?
      return unless @checker
      program_entries(uri)
    end

    # Programs that contain *uri* (a saved `.cr` file).
    private def program_entries(uri : String) : Array(String)?
      path = VFS.path_for(uri) || return
      return unless path.ends_with?(".cr") && File.file?(path)
      return if @indexes.empty?
      idx = index_for(@vfs.id_for(uri))
      entry_points(compile_dir(path)).for(path) do |p|
        idx.entry?(@vfs.id_for(VFS.uri_for(p))).try(&.requires)
      end
    end

    # *path* under the name the server uses for it (`VFS#canonical_uri`).
    private def canonical_path(path : String) : String
      VFS.path_for(@vfs.canonical_uri(VFS.uri_for(path))) || path
    end

    # Per real file, the URI its diagnostics were last published under. A
    # file can change names (the compiler and the client name files
    # differently, a folder alias appears): the old name is cleared, or a
    # client that keys diagnostics by URI keeps them.
    @published_uris = {} of String => String

    private def publish_problems(file : String, problems : Array(Compiler::Problem)) : Nil
      lines = File.file?(file) ? LineIndex.new(File.read(file)) : LineIndex.new("")
      diagnostics = problems.map { |p| diagnostic_json(p, lines) }
      uri = @vfs.canonical_uri(VFS.uri_for(file))
      key = File.realpath(file) rescue file
      if (old = @published_uris[key]?) && old != uri
        @transport.write(JsonRpc.notification("textDocument/publishDiagnostics", {uri: old, diagnostics: [] of String}))
      end
      @published_uris[key] = uri
      @transport.write(JsonRpc.notification("textDocument/publishDiagnostics",
        {uri: uri, diagnostics: diagnostics}))
    rescue ex
      Log.error(exception: ex) { "publishing diagnostics for #{file} failed" }
    end

    private def diagnostic_json(p : Compiler::Problem, lines : LineIndex)
      related = p.trace.compact_map do |f|
        next if f.message == Compiler::Output::MACRO_FRAME && f.file == p.file && f.line == p.frame.line
        index = f.file == p.file ? lines : (File.file?(f.file) ? LineIndex.new(File.read(f.file)) : next)
        {location: {uri: @vfs.canonical_uri(VFS.uri_for(f.file)), range: frame_range(f, index)}, message: f.message}
      end
      {
        range:              frame_range(p.frame, lines),
        severity:           p.severity.error? ? 1 : 2,
        source:             "crystal",
        message:            p.message,
        relatedInformation: related,
      }
    end

    # Compiler columns count codepoints (UTF-32 units). A zero or missing
    # size covers the identifier at the position, else one character.
    private def frame_range(f : Compiler::Frame, lines : LineIndex)
      line = (f.line - 1).clamp(0, nil).to_u32
      col = (f.column - 1).clamp(0, nil).to_u32
      start = lines.offset(LineCol.new(line, col), PositionEncoding::UTF32)
      size = f.size || 0
      stop = if size > 0
               lines.offset(LineCol.new(line, col + size), PositionEncoding::UTF32)
             else
               word_end(lines, start)
             end
      range_json(lines, TextRange.new(start, stop))
    end

    private def word_end(lines : LineIndex, start : UInt32) : UInt32
      bytes = lines.text.to_slice
      limit = lines.line_range(lines.line_of(start)).end
      stop = start
      while stop < limit && (bytes[stop].unsafe_chr.ascii_alphanumeric? || bytes[stop] == '_'.ord || bytes[stop] >= 0x80)
        stop += 1
      end
      stop += 1 if stop < limit && stop > start && bytes[stop].unsafe_chr.in?('?', '!')
      stop == start && start < limit ? start + 1 : stop
    end
  end
end
