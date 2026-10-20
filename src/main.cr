require "option_parser"
require "./clear_ls"

module ClearLS::CLI
  USAGE = <<-TEXT
    Usage: clear-ls [command] [options]

    Commands:
      lsp                 Run the language server on stdio (default)
      dump-cst FILE       Print the Tree-sitter CST of FILE
      dump-items FILE     Print the declarations (item tree) of FILE
      dump-hir FILE LINE  Print the body HIR of the def at LINE (1-based)
      dump-cfg FILE LINE  Print the control-flow graph of the def at LINE
      version             Print version information

    Options:
    TEXT

  def self.run(args : Array(String)) : Int32
    log_level = ::Log::Severity::Info
    log_file = nil.as(String?)
    show_ranges = false

    parser = OptionParser.new do |opts|
      opts.banner = USAGE
      opts.on("--log-level LEVEL", "trace|debug|info|warn|error (default info)") do |v|
        log_level = ::Log::Severity.parse?(v) || abort "unknown log level #{v}"
      end
      opts.on("--log-file PATH", "Write logs to PATH instead of stderr") { |v| log_file = v }
      opts.on("--ranges", "dump-cst: include byte ranges") { show_ranges = true }
      opts.on("-h", "--help", "Show this help") { puts opts; exit 0 }
      opts.invalid_option { |o| STDERR.puts "unknown option #{o}"; STDERR.puts opts; exit 2 }
    end
    parser.parse(args)

    # stdout carries the protocol; logs must never go there.
    backend_io = log_file ? File.open(log_file.not_nil!, "a") : STDERR
    ::Log.setup(log_level, ::Log::IOBackend.new(backend_io))

    case command = args.shift? || "lsp"
    when "lsp"
      STDOUT.sync = false
      server = LSP::Server.new(LSP::Transport.new(STDIN, STDOUT))
      server.run
    when "dump-cst"
      file = args.shift? || abort "dump-cst: missing FILE"
      dump_cst(File.read(file), show_ranges)
      0
    when "dump-items"
      file = args.shift? || abort "dump-items: missing FILE"
      tree = Syntax::Parser.new.parse(File.read(file))
      Items::Dump.dump(Items::Lower.lower(tree), tree.line_index, STDOUT)
      0
    when "dump-hir", "dump-cfg"
      file = args.shift? || abort "#{command}: missing FILE"
      line = (args.shift? || abort "#{command}: missing LINE").to_i - 1
      text = File.read(file)
      tree = Syntax::Parser.new.parse(text)
      offset = tree.line_index.line_range(line.to_u32).start
      node = tree.root.descendant(offset, offset)
      while node && !(node.kind.method_def? || node.kind.abstract_method_def?)
        node = node.parent
      end
      abort "#{command}: no def at line #{line + 1}" unless node
      body = HIR::LowerBody.lower(node)
      if command == "dump-hir"
        HIR::Dump.dump(body, tree.line_index, STDOUT)
      else
        Flow::Builder.build(body).dump(body, text, STDOUT)
      end
      0
    when "version"
      puts "clear-ls #{VERSION}"
      puts "tree-sitter-crystal ABI #{Syntax::Grammar.abi_version}"
      0
    else
      STDERR.puts "unknown command #{command}"
      STDERR.puts parser
      2
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

exit ClearLS::CLI.run(ARGV.dup)
