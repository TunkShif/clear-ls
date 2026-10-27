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
  # `initializationOptions.compiler`:
  # - `enabled` (default true): background checks; explicit requests such
  #   as formatting use the compiler regardless
  # - `path`: crystal executable (default `$CRYSTAL` or `crystal`)
  # - `entries`: main files to check instead of the shard targets
  # - `debounceMs` (default 150)
  # - `facts` (default true): add the facts exporter to each check and
  #   merge generated methods and ivar types into the index
  class Server
    @compiler_options = JSON::Any.new({} of String => JSON::Any)
    @checker : Compiler::Checker? = nil
    @toolchain : Compiler::Toolchain? = nil
    @entry_points : Compiler::EntryPoints? = nil
    # Entry points checked since the last change on disk.
    @checked = Set(String).new

    getter checker

    private def read_compiler_options(params : JSON::Any) : Nil
      @compiler_options = params.dig?("initializationOptions", "compiler") || @compiler_options
    end

    private def compiler_enabled? : Bool
      @compiler_options["enabled"]?.try(&.as_bool?) != false
    end

    # The `crystal` executable for the workspace.
    def toolchain : Compiler::Toolchain
      @toolchain ||= begin
        crystal = @compiler_options["path"]?.try(&.as_s?) || ENV["CRYSTAL"]? || "crystal"
        Compiler::Toolchain.new(crystal, @index.try(&.project.root) || @root)
      end
    end

    private def entry_points : Compiler::EntryPoints
      @entry_points ||= begin
        root = index.project.root
        entries = @compiler_options["entries"]?.try(&.as_a?).try &.compact_map { |e| e.as_s?.try { |s| File.expand_path(s, root) } }
        Compiler::EntryPoints.new(root, entries)
      end
    end

    private def start_compiler : Nil
      return unless compiler_enabled?
      checker = Compiler::Checker.new(toolchain,
        ->(file : String, problems : Array(Compiler::Problem)) { publish_problems(file, problems) })
      @compiler_options["debounceMs"]?.try(&.as_i?).try { |ms| checker.debounce = ms.milliseconds }
      if @compiler_options["facts"]?.try(&.as_bool?) != false
        exporter = File.join(Dir.tempdir, "clear-ls-facts-#{Process.pid}.cr")
        File.write(exporter, Compiler::Exporter.source(index.project.root))
        @exporter_file = exporter
        checker.extra_sources = [exporter]
        checker.on_result = ->(entry : String, result : Compiler::Job::Result) { import_facts(entry, result) }
      end
      @checker = checker
      check_entries(entry_points.targets)
    end

    private def stop_compiler : Nil
      @checker.try(&.stop)
      @exporter_file.try { |f| File.delete?(f) }
    end

    @exporter_file : String? = nil
    # Facts per entry point; merged into the index.
    @entry_facts = {} of String => Workspace::CompilerFacts

    # Takes the facts from one check. A section that the compile did not
    # reach (an error stopped it first) keeps the entry's previous facts.
    private def import_facts(entry : String, result : Compiler::Job::Result) : Nil
      parsed = Compiler::Exporter::Facts.parse(result.stdout)
      old = @entry_facts[entry]?
      methods = parsed.methods || old.try(&.methods) || [] of Compiler::Exporter::MethodFact
      ivars = parsed.ivars || old.try(&.ivars) || [] of Compiler::Exporter::IvarFact
      @entry_facts[entry] = Workspace::CompilerFacts.snapshot(methods, ivars)
      @index.try(&.local).try(&.write_facts(@entry_facts))
      apply_entry_facts
    end

    # Facts of the previous session (local cache), applied before the
    # first check; each file's facts apply only while its text matches
    # the digest taken with them. The first check replaces them.
    private def restore_facts : Nil
      return unless compiler_enabled? && @compiler_options["facts"]?.try(&.as_bool?) != false
      local = @index.try(&.local) || return
      saved = local.read_facts
      return if saved.empty?
      @entry_facts = saved
      apply_entry_facts
    end

    private def apply_entry_facts : Nil
      digests = {} of String => UInt64
      @entry_facts.each_value { |f| digests.merge!(f.digests) }
      merged = Workspace::CompilerFacts.new(
        @entry_facts.values.flat_map(&.methods).uniq,
        @entry_facts.values.flat_map(&.ivars).uniq, digests)
      idx = @index || return
      changed = idx.facts != merged
      idx.facts = merged
      Log.info { "compiler facts: #{merged.methods.size} methods, #{merged.ivars.size} ivars" }
      # Hints and tokens computed before the facts may have been unknown.
      refresh_views if changed
    end

    @refresh_id = 0

    # Asks the client to re-request inlay hints and semantic tokens
    # (when it advertised support); their answers depend on the index.
    private def refresh_views : Nil
      {"inlayHint" => "workspace/inlayHint/refresh", "semanticTokens" => "workspace/semanticTokens/refresh"}.each do |cap, method|
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
      idx = @index || return
      entry_points.for(path) do |p|
        idx.entry?(@vfs.id_for(VFS.uri_for(p))).try(&.requires)
      end
    end

    private def publish_problems(file : String, problems : Array(Compiler::Problem)) : Nil
      lines = File.file?(file) ? LineIndex.new(File.read(file)) : LineIndex.new("")
      diagnostics = problems.map { |p| diagnostic_json(p, lines) }
      @transport.write(JsonRpc.notification("textDocument/publishDiagnostics",
        {uri: VFS.uri_for(file), diagnostics: diagnostics}))
    rescue ex
      Log.error(exception: ex) { "publishing diagnostics for #{file} failed" }
    end

    private def diagnostic_json(p : Compiler::Problem, lines : LineIndex)
      related = p.trace.compact_map do |f|
        next if f.message == Compiler::Output::MACRO_FRAME && f.file == p.file && f.line == p.frame.line
        index = f.file == p.file ? lines : (File.file?(f.file) ? LineIndex.new(File.read(f.file)) : next)
        {location: {uri: VFS.uri_for(f.file), range: frame_range(f, index)}, message: f.message}
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
