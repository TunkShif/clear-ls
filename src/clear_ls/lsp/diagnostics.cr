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
  # - `enabled` (default true)
  # - `path`: crystal executable (default `$CRYSTAL` or `crystal`)
  # - `entries`: main files to check instead of the shard targets
  # - `debounceMs` (default 150)
  class Server
    @compiler_options = JSON::Any.new({} of String => JSON::Any)
    @checker : Compiler::Checker? = nil
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

    private def start_compiler : Nil
      return unless compiler_enabled?
      root = index.project.root
      crystal = @compiler_options["path"]?.try(&.as_s?) || ENV["CRYSTAL"]? || "crystal"
      entries = @compiler_options["entries"]?.try(&.as_a?).try &.compact_map { |e| e.as_s?.try { |s| File.expand_path(s, root) } }
      @entry_points = Compiler::EntryPoints.new(root, entries)
      checker = Compiler::Checker.new(Compiler::Toolchain.new(crystal, root),
        ->(file : String, problems : Array(Compiler::Problem)) { publish_problems(file, problems) })
      @compiler_options["debounceMs"]?.try(&.as_i?).try { |ms| checker.debounce = ms.milliseconds }
      @checker = checker
      check_entries(@entry_points.not_nil!.targets)
    end

    private def stop_compiler : Nil
      @checker.try(&.stop)
    end

    # didOpen: check the programs containing *uri* once.
    private def compiler_opened(uri : String) : Nil
      entries = entries_for(uri) || return
      check_entries(entries.reject { |e| @checked.includes?(e) })
    end

    # didSave / disk change of *uri*: everything checked before is stale.
    private def compiler_saved(uri : String) : Nil
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
      path = VFS.path_for(uri) || return
      return unless path.ends_with?(".cr") && File.file?(path)
      idx = @index || return
      @entry_points.not_nil!.for(path) do |p|
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
