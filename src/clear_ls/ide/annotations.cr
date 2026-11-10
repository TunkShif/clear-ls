module ClearLS::IDE
  # The compiler's own annotations (`Program#initialize`,
  # compiler/crystal/program.cr). Ten have no source declaration
  # (`AlwaysInline`, `Raises`, ...); `Link`, `Flags`, `Deprecated`,
  # `Experimental` and `TargetFeature` are also declared in the stdlib's
  # annotations.cr, whose docs win. Arguments are the ones the compiler
  # reads (codegen/link.cr, semantic/top_level_visitor.cr,
  # semantic/warnings.cr, codegen/experimental.cr) as of Crystal 1.22.
  module Annotations
    # An argument. *position*: its index when it may be given
    # positionally; *named*: whether `name: value` is accepted.
    record Arg, name : String, type : String, doc : String, position : Int32? = nil, named : Bool = true

    record Builtin, name : String, doc : String, targets : String, args : Array(Arg) = [] of Arg,
      # Declared in the stdlib (annotations.cr).
      declared : Bool = false

    CALL_CONVENTIONS = %w(C Fast Cold WebKit_JS AnyReg X86_StdCall X86_FastCall)

    BUILTINS = [
      Builtin.new("AlwaysInline", "Asks LLVM to always inline the method (`alwaysinline`).", "`def`, `fun`"),
      Builtin.new("NoInline", "Asks LLVM never to inline the method (`noinline`).", "`def`, `fun`"),
      Builtin.new("Naked", "Emits the function without prologue and epilogue (`naked`); the body is usually `asm`.", "`def`, `fun`"),
      Builtin.new("ReturnsTwice", "The function may return more than once, like `setjmp` (`returns_twice`).", "`def`, `fun`"),
      Builtin.new("Raises", "The C function may raise (it calls back into Crystal code that raises): calls to it are emitted so that `rescue` catches the exception.", "`fun`, `def`"),
      Builtin.new("CallConvention", "Calling convention of a `fun`, or of every `fun` of a `lib`.", "`lib`, `fun`",
        [Arg.new("convention", "String", "one of #{CALL_CONVENTIONS.map { |c| "`#{c}`" }.join(", ")}", position: 0, named: false)]),
      Builtin.new("Extern", "Lays the struct out like a C struct, so it can be passed to and from C.", "non-generic `struct`",
        [Arg.new("union", "Bool", "lay it out like a C union instead")]),
      Builtin.new("Packed", "No padding between the fields.", "`struct` inside a `lib`, `@[Extern]` struct"),
      Builtin.new("ThreadLocal", "One value per thread.", "class variable, `$var` inside a `lib`"),
      Builtin.new("Primitive", "The method is implemented by the compiler (stdlib only).", "`def`, `fun`",
        [Arg.new("name", "Symbol", "the primitive", position: 0, named: false)]),
      Builtin.new("Flags", "Enum members are bit flags: the first is 1, each next one doubles.", "`enum`", declared: true),
      Builtin.new("Link", "The library a `lib` links against.", "`lib`",
        [Arg.new("lib", "String", "library name: looked up with `pkg-config`, else passed as `-l`", position: 0),
         Arg.new("ldflags", "String", "passed to the linker as is", position: 1),
         Arg.new("static", "Bool", "link statically (deprecated)", position: 2),
         Arg.new("framework", "String", "macOS framework (`-framework`)", position: 3),
         Arg.new("pkg_config", "String", "`pkg-config` name to try before *lib*"),
         Arg.new("wasm_import_module", "String", "WebAssembly import module of the funs"),
         Arg.new("dll", "String", "Windows DLL copied next to the program (`.dll`, no directory)")], declared: true),
      Builtin.new("Deprecated", "Marks a feature as deprecated; the compiler warns where it is used.", "`def`, `macro`, type, constant, `alias`, parameter",
        [Arg.new("message", "String", "deprecation notice", position: 0, named: false)], declared: true),
      Builtin.new("Experimental", "Marks a feature as experimental.", "`def`, `macro`, type, constant",
        [Arg.new("message", "String", "notice", position: 0, named: false)], declared: true),
      Builtin.new("TargetFeature", "Compiles the method for extra CPU features or another CPU model.", "`def`, `fun`",
        [Arg.new("features", "String", "LLVM features, as for `--mattr` (`\"+avx2\"`)", position: 0, named: false),
         Arg.new("cpu", "String", "CPU model, as for `--mcpu`")], declared: true),
    ]

    BY_NAME = BUILTINS.to_h { |b| {b.name, b} }

    # Arguments of stdlib annotations, by full name, as their macros read
    # them (`ann[:key]` in json/serialization.cr, yaml/serialization.cr,
    # uri/params/serializable.cr; Crystal 1.22). Docs from the
    # `Serializable` modules. Used only when the annotation is declared
    # in the stdlib.
    private IGNORE = Arg.new("ignore", "Bool", "skip this field in serialization and deserialization (default `false`)")
    private IGNORE_SER = Arg.new("ignore_serialize", "Bool", "if truthy, skip this field in serialization (default `false`); any Crystal expression, evaluated at runtime")
    private IGNORE_DESER = Arg.new("ignore_deserialize", "Bool", "skip this field in deserialization (default `false`)")
    private PRESENCE = Arg.new("presence", "Bool", "generate a `@{{key}}_present` instance variable, true when the key was present (even with a `null` value); default `false`")
    private EMIT_NULL = Arg.new("emit_null", "Bool", "emit `null` for a nilable property (default: nulls are not emitted)")
    private EMIT_NULLS = Arg.new("emit_nulls", "Bool", "emit `null` for all nilable properties (default: nulls are not emitted)")

    STDLIB_ARGS = {
      "JSON::Field" => [
        IGNORE, IGNORE_SER, IGNORE_DESER,
        Arg.new("key", "String", "key in the JSON object (default: the instance variable's name)"),
        Arg.new("root", "String", "the value is inside a JSON object under this key (see `Object.from_json(string_or_io, root)`)"),
        Arg.new("converter", "", "type used for parsing and generation: defines `from_json(JSON::PullParser)` and `to_json(value, JSON::Builder)` (e.g. `Time::EpochConverter`)"),
        PRESENCE, EMIT_NULL,
      ],
      "YAML::Field" => [
        IGNORE, IGNORE_SER, IGNORE_DESER,
        Arg.new("key", "String", "key in the YAML object (default: the instance variable's name)"),
        Arg.new("converter", "", "type used for parsing and generation: defines `from_yaml(YAML::ParseContext, YAML::Nodes::Node)` and `to_yaml(value, YAML::Nodes::Builder)` (e.g. `Time::EpochConverter`)"),
        PRESENCE, EMIT_NULL,
      ],
      "URI::Params::Field" => [
        IGNORE, IGNORE_SER, IGNORE_DESER,
        Arg.new("converter", "", "type used for parsing: defines `.from_www_form(params : URI::Params, name : String)`"),
      ],
      "JSON::Serializable::Options" => [EMIT_NULLS],
      "YAML::Serializable::Options" => [EMIT_NULLS],
    }

    # Single-segment names the compiler resolves at the top level inside
    # `@[…]`, whatever the scope (`semantic_visitor.cr`: `File::Flags`
    # would shadow `Flags` otherwise).
    TOP_LEVEL = {"Primitive", "Flags"}

    # The built-in named by *path* as written (`Link`, `::Link`).
    def self.builtin?(path : String) : Builtin?
      BY_NAME[path.lchop("::")]?
    end

    # Markdown for a built-in. *source_doc*: the stdlib declaration's doc,
    # used instead of the table's one-liner.
    def self.markdown(b : Builtin, source_doc : String? = nil) : String
      String.build do |io|
        io << "```crystal\nannotation " << b.name << "\n```\n\n"
        io << (source_doc || b.doc)
        io << "\n\nApplies to: " << b.targets
        unless b.args.empty?
          io << "\n\nArguments:\n"
          b.args.each { |a| io << "\n- " << arg_line(a) }
        end
        io << "\n\nbuilt into the compiler" << (b.declared ? "" : " (no source declaration)")
      end
    end

    # `` `name : Type` — doc (1st positional) ``
    def self.arg_line(a : Arg) : String
      String.build do |io|
        io << '`' << a.name << " : " << a.type << "` — " << a.doc
        if pos = a.position
          io << (a.named ? " (also positional #" : " (positional #") << pos + 1 << ')'
        end
      end
    end
  end
end
