require "option_parser"
require "./clear_ls"

module ClearLS::CLI
  # A user error: printed as `clear-ls: message`, exit 2, no trace.
  class UsageError < Exception
  end

  USAGE = <<-TEXT
    Usage: clear-ls [command] [options]

    Commands:
      lsp                 Run the language server on stdio (default)
      dump-cst FILE       Print the Tree-sitter CST of FILE
      dump-items FILE     Print the declarations (item tree) of FILE
      dump-hir FILE LINE  Print the body HIR of the def at LINE (1-based)
      dump-cfg FILE LINE  Print the control-flow graph of the def at LINE
      cache info [ROOT]   Print cache locations and pack sizes
      cache clear [ROOT]  Delete ROOT's local cache and the global packs it uses
      settings-doc        Print the settings reference (docs/settings.md)
      version             Print version information

    Options:
    TEXT

  # Runs a command; user errors (bad arguments, unreadable files) become
  # one line on stderr. With `--log-level debug` the trace is kept.
  def self.main(args : Array(String)) : Int32
    run(args)
  rescue ex : UsageError
    STDERR.puts "clear-ls: #{ex.message}"
    2
  rescue ex : File::Error | IO::Error
    STDERR.puts "clear-ls: #{ex.message}"
    ex.inspect_with_backtrace(STDERR) if debug?
    1
  rescue ex : OptionParser::Exception
    STDERR.puts "clear-ls: #{ex.message}"
    STDERR.puts "Run `clear-ls --help` for usage."
    2
  end

  private def self.debug? : Bool
    i = ARGV.index("--log-level")
    !i.nil? && ARGV[i + 1]?.in?("debug", "trace")
  end

  private def self.read(file : String) : String
    raise UsageError.new("#{file}: is a directory") if Dir.exists?(file)
    File.read(file)
  rescue ex : File::NotFoundError
    raise UsageError.new("#{file}: no such file")
  rescue ex : File::AccessDeniedError
    raise UsageError.new("#{file}: permission denied")
  rescue ex : File::Error
    raise UsageError.new("#{file}: #{ex.os_error.try(&.message) || ex.message}")
  end

  private def self.need(args : Array(String), command : String, what : String) : String
    args.shift? || raise UsageError.new("#{command}: missing #{what}")
  end

  def self.run(args : Array(String)) : Int32
    log_level = ::Log::Severity::Info
    log_file = nil.as(String?)
    show_ranges = false
    use_cache = true

    parser = OptionParser.new do |opts|
      opts.banner = USAGE
      opts.on("--log-level LEVEL", "trace|debug|info|warn|error (default info)") do |v|
        log_level = ::Log::Severity.parse?(v) || raise UsageError.new("unknown log level #{v} (trace, debug, info, warn, error)")
      end
      opts.on("--log-file PATH", "Write logs to PATH instead of stderr") { |v| log_file = v }
      opts.on("--no-cache", "lsp: don't read or write the persistent index cache") { use_cache = false }
      opts.on("--ranges", "dump-cst: include byte ranges") { show_ranges = true }
      opts.on("-h", "--help", "Show this help") { puts opts; exit 0 }
      opts.invalid_option { |o| raise UsageError.new("unknown option #{o} (see --help)") }
      opts.missing_option { |o| raise UsageError.new("#{o} needs a value") }
    end
    parser.parse(args)

    # stdout carries the protocol; logs must never go there.
    backend_io = if path = log_file
                   begin
                     File.open(path, "a")
                   rescue ex : File::Error
                     raise UsageError.new("--log-file #{path}: #{ex.os_error.try(&.message) || ex.message}")
                   end
                 else
                   STDERR
                 end
    ::Log.setup(log_level, ::Log::IOBackend.new(backend_io))

    case command = args.shift? || "lsp"
    when "lsp"
      STDOUT.sync = false
      server = LSP::Server.new(LSP::Transport.new(STDIN, STDOUT))
      server.cache_allowed = use_cache
      server.warmup_allowed = true
      server.run
    when "dump-cst"
      file = need(args, command, "FILE")
      dump_cst(read(file), show_ranges)
      0
    when "dump-items"
      file = need(args, command, "FILE")
      tree = Syntax::Parser.new.parse(read(file))
      Items::Dump.dump(Items::Lower.lower(tree), tree.line_index, STDOUT)
      0
    when "dump-hir", "dump-cfg"
      file = need(args, command, "FILE")
      line_arg = need(args, command, "LINE")
      line = (line_arg.to_i? || raise UsageError.new("#{command}: LINE must be a number, got #{line_arg.inspect}")) - 1
      text = read(file)
      tree = Syntax::Parser.new.parse(text)
      unless 0 <= line < tree.line_index.line_count
        raise UsageError.new("#{command}: #{file} has #{tree.line_index.line_count} lines, got #{line + 1}")
      end
      offset = tree.line_index.line_range(line.to_u32).start
      node = tree.root.descendant(offset, offset)
      while node && !(node.kind.method_def? || node.kind.abstract_method_def?)
        node = node.parent
      end
      raise UsageError.new("#{command}: no def at line #{line + 1}") unless node
      body = HIR::LowerBody.lower(node)
      if command == "dump-hir"
        HIR::Dump.dump(body, tree.line_index, STDOUT)
      else
        Flow::Builder.build(body).dump(body, text, STDOUT)
      end
      0
    when "cache"
      sub = args.shift? || "info"
      raise UsageError.new("cache: unknown subcommand #{sub} (info, clear)") unless sub.in?("info", "clear")
      root = File.expand_path(args.shift? || Dir.current)
      project = Workspace::Project.detect(root)
      store = Cache::Store.new(Cache::Store.default_dir, project.stdlib_dir, project.crystal_version, project.root)
      local = File.join(Cache::Local.dir_for(project.root), "cache")
      case sub
      when "info"
        puts "build key #{Cache.build_key}"
        puts "global #{store.dir}"
        store.pack_keys.each do |k|
          path = store.pack_path(k)
          puts "  #{File.basename(path)} #{File.exists?(path) ? "#{File.size(path) // 1024} KB" : "(none)"}"
        end
        puts "local #{local}"
        Dir.glob(File.join(local, "*.pack")).sort.each { |p| puts "  #{File.basename(p)} #{File.size(p) // 1024} KB" }
      when "clear"
        store.pack_keys.each { |k| File.delete?(store.pack_path(k)) }
        Cache::Local.clear(project.root)
        puts "cleared #{local} and #{store.pack_keys.size} global packs"
      else
        raise UsageError.new("cache: unknown subcommand #{sub} (info, clear)")
      end
      0
    when "settings-doc"
      print LSP::Settings.markdown
      0
    when "version"
      puts "clear-ls #{VERSION} (#{Cache::BUILD_ID})"
      puts "tree-sitter-crystal ABI #{Syntax::Grammar.abi_version}"
      0
    else
      raise UsageError.new("unknown command #{command} (see --help)")
    end
  end

  # Indented CST with fields; anonymous tokens are omitted.
  def self.dump_cst(text : String, show_ranges : Bool, io : IO = STDOUT) : Nil
    tree = Syntax::Parser.new.parse(text)
    dump_node(tree.root, nil, 0, show_ranges, io)
  end

  private def self.dump_node(node : Syntax::Node, field : Syntax::Field?, depth : Int32, ranges : Bool, io : IO) : Nil
    io << "  " * depth
    io << Syntax::FIELD_NAMES[field.value] << ": " if field && !field.none?
    io << (node.missing? ? "MISSING " : "") << node.type
    if ranges
      a, b = node.tree.line_index.point(node.start_byte), node.tree.line_index.point(node.end_byte)
      io << " [" << a << " - " << b << ']'
    end
    if node.named_child_count == 0 && node.named? && !node.error?
      io << ' ' << node.text.inspect if node.end_byte - node.start_byte <= 60
    end
    io << '\n'
    node.each_child_with_field do |child, f|
      next unless child.named? || child.missing?
      dump_node(child, f, depth + 1, ranges, io)
    end
  end
end

exit ClearLS::CLI.main(ARGV.dup)
