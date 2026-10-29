require "./typing"
require "./analysis"
require "./signature_help"
require "./references"
require "./statement_site"

module ClearLS::IDE
  enum CompletionKind
    Method
    Function
    Variable
    Field     # ivar / cvar
    Class
    Struct
    Module
    Enum
    EnumMember
    Constant
    Keyword
    Snippet
    Macro
  end

  record CompletionItem,
    label : String,
    kind : CompletionKind,
    detail : String? = nil,
    documentation : String? = nil,
    sort_text : String? = nil,
    insert_text : String? = nil,
    overloads : Int32 = 1,
    # Some overload takes no argument (`a.-` is unary minus).
    nullary : Bool = false,
    # Every overload takes a block; the first one's site (for parameter
    # names).
    block_site : Semantics::Site? = nil,
    # Replaces *edit_range* (instead of the word before the cursor) with
    # *insert_text*; for setters and operators, which rewrite `.`.
    edit_range : TextRange? = nil,
    filter_text : String? = nil,
    # *insert_text* is an LSP snippet (`$1`, `$0`).
    snippet : Bool = false,
    # Multi-line *insert_text* written with `\t` and newlines: the client
    # re-indents it to the line (`insertTextMode: adjustIndentation`).
    adjust_indent : Bool = false

  # What the client can take (`textDocument.completion.completionItem`)
  # and the settings that shape items.
  record CompletionOptions, snippets : Bool = false, setter_snippets : Bool = true,
    block_snippets : Bool = true, block_style : String = "braces",
    do_snippet : Bool = true, case_snippets : Bool = true,
    definition_snippets : Bool = false, control_flow_snippets : Bool = false

  # Completion at a cursor.
  #
  # Incomplete code (`s.`, `IO::`) parses badly: Tree-sitter often pulls the
  # next line's word in as the method name. We therefore analyse a copy of
  # the text with a placeholder identifier inserted at the cursor, which
  # turns `s.|` into `s.__cl__`, `IO::|` into `IO::CL__`, and keeps the
  # surrounding statements intact. Nothing from that copy is cached.
  class Completion
    PLACEHOLDER = "__cl__"
    CONST_PLACEHOLDER = "CL__"
    MAX_ITEMS = 400

    def initialize(@state : FileState, @index : Workspace::Index, @typing : Typing, @options = CompletionOptions.new)
    end

    def complete(offset : UInt32) : Array(CompletionItem)
      text = @state.text
      prefix_start = word_start(text, offset)
      prefix = text.byte_slice(prefix_start, offset - prefix_start)
      before = prefix_start > 0 ? text.byte_slice(0, prefix_start) : ""

      if before.ends_with?("::")
        const_members(text, prefix_start, offset, prefix)
      elsif before.ends_with?('.') && !before.ends_with?("..")
        members(text, prefix_start, offset, prefix)
      elsif prefix.starts_with?('@')
        ivars(prefix_start, prefix)
      elsif prefix[0]?.try(&.uppercase?)
        scope_constants(prefix_start, prefix)
      else
        identifiers(text, prefix_start, offset, prefix)
      end
    end

    # -- receiver members (`x.|`) ---------------------------------------------------

    private def members(text : String, start : UInt32, offset : UInt32, prefix : String) : Array(CompletionItem)
      patched, at = patch(text, start, offset, PLACEHOLDER)
      call_node, state = patched_node(patched, at)
      return [] of CompletionItem unless call_node && state
      recv_t = if recv_node = call_node.field(Syntax::Field::Receiver)
                 receiver_type(state, recv_node)
               elsif call_node.kind.implicit_object_call?
                 # `&.|` / `when .|`: the block argument or case subject.
                 implicit_receiver_type(state, call_node)
               end
      return [] of CompletionItem unless recv_t
      items = method_items(recv_t, prefix)
      # The `.` before the word, and whether this is `&.` (short block).
      dot = start - 1
      short_block = dot > 0 && text.byte_at(dot - 1) == '&'.ord
      items = items.map { |i| shape_member(i, dot, offset, short_block) } if @options.setter_snippets
      # A block is never written after `&.x` (it is the block), nor when
      # the call already continues (`xs.map(` / `xs.map {` after the word).
      rest = text.byte_slice(offset, Math.min(2, text.bytesize - offset)).lstrip
      if @options.snippets && @options.block_snippets && !short_block && !rest.starts_with?('{') && !rest.starts_with?('(') && !rest.starts_with?("do")
        items = items.map { |i| with_block(i, start, offset) }
      end
      items
    end

    # `map` → `map { |${1:x}| $0 }` for methods whose every overload
    # takes a block. Parameter names from the def (`yield elem, i`), else
    # placeholders `x`, `y`, ...
    private def with_block(i : CompletionItem, start : UInt32, offset : UInt32) : CompletionItem
      site = i.block_site || return i
      return i unless i.edit_range.nil? && i.label[0].letter?
      names = @typing.block_param_names(site) || return i
      fallback = %w(x y z w)
      params = names.map_with_index do |n, k|
        "${#{k + 1}:#{n || fallback[k]? || "x#{k}"}}"
      end
      bar = params.empty? ? "" : "|#{params.join(", ")}| "
      text = if @options.block_style == "do"
               "#{i.label} do #{bar.rstrip}\n\t$0\nend"
             else
               "#{i.label} { #{bar}$0 }"
             end
      i.copy_with(insert_text: text, edit_range: TextRange.new(start, offset), filter_text: i.label, snippet: true)
    end

    UNARY = %w(- + ! ~)

    # Setter and operator items as they are written: `x.name = `,
    # `x + `, `x[]`. *dot* is the `.` before the word; edits replace from
    # there (operators) or from the word (setters) up to *offset*.
    private def shape_member(i : CompletionItem, dot : UInt32, offset : UInt32, short_block : Bool) : CompletionItem
      name = i.label
      if References.setter?(name)
        base = name.rchop('=')
        # `filterText` keeps the item visible while typing the base name.
        return i.copy_with(insert_text: "#{base} = ", edit_range: TextRange.new(dot + 1, offset), filter_text: base)
      end
      return i if name[0].letter? || name[0] == '_'
      # Operators. `&.+ 1` is a valid short block: keep `.`.
      return i if short_block
      case name
      when "[]", "[]?"
        text = @options.snippets ? "[$1]#{name == "[]?" ? "?" : ""}" : "[]#{name == "[]?" ? "?" : ""}"
        i.copy_with(insert_text: text, edit_range: TextRange.new(dot, offset), filter_text: name, snippet: @options.snippets)
      when "[]="
        text = @options.snippets ? "[$1] = " : "[] = "
        i.copy_with(insert_text: text, edit_range: TextRange.new(dot, offset), filter_text: name, snippet: @options.snippets)
      else
        # Binary operators: `a.` + `+` → `a + `. An operator that is only
        # unary (`!`, `~`) keeps the call form; `-`/`+` with a binary
        # overload become binary.
        return i if UNARY.includes?(name) && i.nullary && i.overloads == 1
        i.copy_with(insert_text: " #{name} ", edit_range: TextRange.new(dot, offset), filter_text: name)
      end
    end

    private def implicit_receiver_type(state : FileState, call : Syntax::Node) : Types::TyId?
      bodies = Bodies.new(state)
      _, inf = @typing.infer_at(state, bodies, call.start_byte, cache: false) || return nil
      body = bodies.at(call.start_byte) || return nil
      expr = body.exprs.find { |e| e.range == call.range && e.kind.call? } || return nil
      t = inf.implicit_receiver_type(expr.id) || return nil
      @typing.table.unknown?(t) ? nil : t
    end

    # Type of the receiver expression in the patched copy.
    private def receiver_type(state : FileState, recv : Syntax::Node) : Types::TyId?
      bodies = Bodies.new(state)
      _, inf = @typing.infer_at(state, bodies, recv.start_byte, cache: false) || return nil
      body = bodies.at(recv.start_byte) || return nil
      expr = body.exprs.find { |e| e.range == recv.range && !e.kind.seq? } || return nil
      t = inf.type_of(expr.id)
      @typing.table.unknown?(t) ? nil : t
    end

    def method_items(recv_t : Types::TyId, prefix : String) : Array(CompletionItem)
      table = @typing.table
      map = @typing.def_map
      by_name = {} of String => {Array(Semantics::Site), Int32}
      depth_of = {} of String => Int32
      table.members(recv_t).each do |member|
        t = table[member]
        owner, class_side = case t.kind
                            when .named?     then {t.def_id.not_nil!, false}
                            when .metaclass? then table[t.args[0]].def_id.try { |d| {d, true} } || next
                            when .tuple?, .named_tuple?
                              {map.lookup_path("::Tuple") || next, false}
                            when .proc? then {map.lookup_path("::Proc") || next, false}
                            else             next
                            end
        ancestors = map.ancestors(owner)
        ancestors.each_with_index do |anc, depth|
          map[anc].members.each do |key, sites|
            name = if class_side
                     key.starts_with?("self.") ? key.lchop("self.") : next
                   else
                     key.starts_with?("self.") ? next : key
                   end
            next unless name.starts_with?(prefix)
            defs = sites.select { |s| s.item.kind.def? || s.item.kind.macro? }
            next if defs.empty?
            defs = defs.reject { |s| s.item.visibility.private? }
            next if defs.empty?
            next if name == "initialize"
            prev = by_name[name]?
            by_name[name] = {(prev.try(&.[0]) || [] of Semantics::Site) + defs, Math.min(prev.try(&.[1]) || depth, depth)}
          end
        end
        if class_side
          # Every class responds to `.new`.
          if "new".starts_with?(prefix) && !by_name.has_key?("new")
            inits = map.lookup_member(owner, "initialize")
            by_name["new"] = {inits, 0}
          end
          map.extends(owner).each do |ext|
            map[ext].members.each do |key, sites|
              next if key.starts_with?("self.") || !key.starts_with?(prefix)
              defs = sites.select(&.item.kind.def?)
              by_name[key] = {defs, 0} unless defs.empty? || by_name.has_key?(key)
            end
          end
        end
      end
      # A union (`Bar | Baz`) offers what every member responds to, like
      # the compiler's virtual type of the common ancestor (decision 1 in
      # book-gaps.md): a method only one member has would not compile.
      members = table.members(recv_t).reject { |m| table.nil_type?(m) && table.members(recv_t).size > 1 }
      if members.size > 1
        by_name.select! { |name, _| members.all? { |m| member_has?(m, name) } }
      end
      by_name.map do |name, (sites, depth)|
        first = sites.first?
        sig = first.try(&.item.signature)
        detail = sig ? "#{name}#{sig}" : name
        detail += "  (+#{sites.size - 1} overloads)" if sites.size > 1
        tier = member_tier(name, sites)
        CompletionItem.new(name, first.try(&.item.kind.macro?) ? CompletionKind::Macro : CompletionKind::Method,
          detail: detail, documentation: first.try(&.item.doc),
          sort_text: "#{tier}#{depth.to_s.rjust(2, '0')}#{name}", overloads: sites.size,
          nullary: sites.any? { |s| s.item.signature.try(&.params.none? { |p| p.kind.positional? || p.kind.splat? }) || false },
          block_site: sites.all? { |s| s.item.signature.try(&.params.any?(&.kind.block?)) || false } ? first : nil)
      end.sort_by!(&.sort_text.not_nil!).first(MAX_ITEMS)
    end

    # Base types whose methods every value has; listed after the receiver's
    # own methods.
    GENERIC_OWNERS = %w(Object Reference Value Struct Class Comparable Kernel)

    # Sort tier: 0 the receiver's methods, 1 methods from universal base
    # types, 2 operators (`==`, `+`, `[]`, ...).
    # Does a value of type *member* respond to *name* (own or inherited
    # def/macro, or a class-side one for metaclasses)?
    private def member_has?(member : Types::TyId, name : String) : Bool
      table = @typing.table
      map = @typing.def_map
      t = table[member]
      owner = case t.kind
              when .named?                then t.def_id
              when .metaclass?            then table[t.args[0]].def_id
              when .tuple?, .named_tuple? then map.lookup_path("::Tuple")
              when .proc?                 then map.lookup_path("::Proc")
              end
      return true unless owner
      key = t.kind.metaclass? ? "self.#{name}" : name
      map.lookup_member(owner, key).any? { |s| s.item.kind.def? || s.item.kind.macro? } ||
        (t.kind.metaclass? && map.extends(owner).any? { |e| !map.lookup_member(e, name).empty? }) ||
        (t.kind.metaclass? && name == "new")
    end

    private def member_tier(name : String, sites : Array(Semantics::Site)) : Int32
      return 2 unless name[0].letter? || name[0] == '_'
      map = @typing.def_map
      generic = sites.all? do |s|
        owner = map.namespace_at(s.file, s.item.range.start)
        # `:nodoc:` methods are internal API.
        GENERIC_OWNERS.includes?(map[owner].full_name) || s.item.doc.try(&.starts_with?(":nodoc:")) || false
      end
      generic ? 1 : 0
    end

    # -- `Foo::|` -------------------------------------------------------------------

    private def const_members(text : String, start : UInt32, offset : UInt32, prefix : String) : Array(CompletionItem)
      # Path before `::`.
      path_end = start - 2
      path_start = path_end
      while path_start > 0
        c = text.byte_at(path_start - 1).chr
        break unless c.alphanumeric? || c == '_' || c == ':'
        path_start -= 1
      end
      path = text.byte_slice(path_start, path_end - path_start)
      map = @typing.def_map
      ns = map.namespace_at(@state.id, start)
      target = path.empty? ? Semantics::DefMap::PROGRAM : (map.lookup_path(path, ns) || return [] of CompletionItem)
      type_items(target, prefix, own_only: true)
    end

    private def type_items(target : Semantics::TypeId, prefix : String, own_only : Bool) : Array(CompletionItem)
      map = @typing.def_map
      info = map[target]
      items = [] of CompletionItem
      info.types.each do |name, id|
        next unless name.starts_with?(prefix)
        t = map[id]
        next if t.private_type?
        items << CompletionItem.new(name, type_kind(t.kind), detail: t.full_name, documentation: t.doc, sort_text: "0#{name}")
      end
      info.members.each do |name, sites|
        next unless name.starts_with?(prefix)
        if c = sites.find(&.item.kind.constant?)
          kind = info.kind.enum? ? CompletionKind::EnumMember : CompletionKind::Constant
          items << CompletionItem.new(name, kind, detail: c.item.detail.try { |d| "= #{d}" }, documentation: c.item.doc, sort_text: "1#{name}")
        end
      end
      items.first(MAX_ITEMS)
    end

    private def type_kind(k : Semantics::TypeKind) : CompletionKind
      case k
      when .class?, .annotation? then CompletionKind::Class
      when .struct?, .c_struct?, .c_union? then CompletionKind::Struct
      when .enum?                then CompletionKind::Enum
      when .module?, .lib?       then CompletionKind::Module
      else                            CompletionKind::Class
      end
    end

    # Constants visible from the cursor: enclosing namespaces, their
    # ancestors, and the top level.
    private def scope_constants(start : UInt32, prefix : String) : Array(CompletionItem)
      map = @typing.def_map
      seen = Set(String).new
      items = [] of CompletionItem
      cur = map.namespace_at(@state.id, start).as(Semantics::TypeId?)
      while c = cur
        map.ancestors(c).each do |anc|
          type_items(anc, prefix, own_only: true).each { |i| items << i if seen.add?(i.label) }
        end
        cur = map[c].namespace
      end
      items.first(MAX_ITEMS)
    end

    # -- `@|` -----------------------------------------------------------------------

    # Instance / class variables of the enclosing type and its ancestors:
    # declared (`@x : T`), from accessor macros, `initialize(@x)` params
    # and `@x = v` assignments (all ivar items).
    private def ivars(start : UInt32, prefix : String) : Array(CompletionItem)
      map = @typing.def_map
      ns = map.namespace_at(@state.id, start)
      class_var = prefix.starts_with?("@@")
      kind = class_var ? Items::ItemKind::ClassVar : Items::ItemKind::InstanceVar
      found = {} of String => String?
      map.ancestors(ns).each do |anc|
        map[anc].members.each do |name, sites|
          next unless name.starts_with?(prefix) && sites.any? { |s| s.item.kind == kind }
          found[name] ||= sites.compact_map { |s| s.item.detail.try { |d| d.lchop(": ") } }.first?
        end
      end
      found.map { |name, detail| CompletionItem.new(name, CompletionKind::Field, detail: detail) }
    end

    # -- bare identifiers -------------------------------------------------------------

    private def identifiers(text : String, start : UInt32, offset : UInt32, prefix : String) : Array(CompletionItem)
      items = [] of CompletionItem
      seen = Set(String).new
      named_args(start, prefix).each { |i| items << i if seen.add?(i.label) }
      # Locals visible at the cursor (from the patched copy so that half
      # typed code still lowers).
      patched, at = patch(text, start, offset, PLACEHOLDER)
      _, state = patched_node(patched, at)
      with_self = nil.as(Types::TyId?)
      if state
        bodies = Bodies.new(state)
        if body = bodies.at(at)
          _, inf = @typing.infer_at(state, bodies, at, cache: false) || {nil, nil}
          with_self = inf.try(&.with_self_at(at))
          body.visible_bindings(at).each do |b|
            next unless b.name.starts_with?(prefix) && b.name != PLACEHOLDER && seen.add?(b.name)
            # Type at the cursor (flow-sensitive), else the join of writes.
            detail = inf.try do |i|
              t = i.binding_type_at(b.id, at) || i.binding_type(b.id)
              @typing.table.unknown?(t) ? nil : @typing.table.to_s(t)
            end
            items << CompletionItem.new(b.name, CompletionKind::Variable, detail: detail, sort_text: "0#{b.name}")
          end
        end
      end
      # Methods callable on self (instance or class side) and top-level defs.
      map = @typing.def_map
      ns = map.namespace_at(@state.id, start)
      # Inside `with x yield` blocks, calls without a receiver go to x.
      self_t = with_self || @typing.self_type(ns)
      unless @typing.table.unknown?(self_t)
        method_items(self_t, prefix).each do |i|
          items << CompletionItem.new(i.label, i.kind, i.detail, i.documentation, "1#{i.sort_text}", i.insert_text, i.overloads) if seen.add?(i.label)
        end
      end
      # Top-level defs and macros, then those of modules included at the
      # top level (`include Spec::Expectations`: `eq`, `be_nil`, ...).
      map.ancestors(Semantics::DefMap::PROGRAM).each do |anc|
        map[anc].members.each do |name, sites|
          next unless name.starts_with?(prefix) && !name.starts_with?("self.") && !seen.includes?(name)
          # `private def` at top level is file-private.
          site = sites.find { |s| (s.item.kind.def? || s.item.kind.macro?) && (!s.item.visibility.private? || s.file == @state.id) } || next
          seen << name
          sig = site.item.signature
          kind = site.item.kind.macro? ? CompletionKind::Macro : CompletionKind::Function
          items << CompletionItem.new(name, kind, detail: sig ? "#{name}#{sig}" : nil, documentation: site.item.doc, sort_text: "2#{name}")
        end
      end
      KEYWORDS.each do |kw|
        items << CompletionItem.new(kw, CompletionKind::Keyword, sort_text: "3#{kw}") if kw.starts_with?(prefix) && seen.add?(kw)
      end
      do_snippet(text, start, offset, prefix).try { |i| items.unshift(i) }
      items.first(MAX_ITEMS)
    end

    # -- `xs.each do|` ----------------------------------------------------------------

    # `do |${1:x}|\n\t$0\nend` for the word `d`/`do` after a call on the
    # same line that takes a block. The block parameters come from the
    # called def (as block snippets); a call that resolves to defs none of
    # which takes a block gets nothing, an unknown call a plain
    # `do ... end`. The word is replaced by `do\nend` in a copy, so the
    # parser attaches the block to the call it would bind to (`foo bar do`
    # binds to `foo`).
    private def do_snippet(text : String, start : UInt32, offset : UInt32, prefix : String) : CompletionItem?
      return nil unless @options.snippets && @options.do_snippet
      return nil if prefix.empty? || !"do".starts_with?(prefix)
      return nil unless StatementSite.rest_blank?(text, offset)
      # Something before the word on its line, separated by a space.
      return nil unless start > 0 && text.byte_at(start - 1).chr.in?(' ', '\t')
      line_start = start
      while line_start > 0 && text.byte_at(line_start - 1) != '\n'.ord
        line_start -= 1
      end
      return nil if text.byte_slice(line_start, start - line_start).strip.empty?
      patched = Syntax::TextEdit.new(TextRange.new(start, offset), "do\nend").apply(text)
      tree = Syntax::Parser.new.parse(patched)
      state = FileState.new(@state.id, @state.uri, @state.revision ^ 0x2000_0000_0000_0000_u64, @state.version, tree)
      block = tree.root.descendant(start, start + 2)
      while (b = block) && !(b.kind.block? && b.start_byte == start)
        block = b.parent
      end
      call_node = block.try(&.parent)
      Syntax.keep_alive(tree)
      return nil unless call_node && (call_node.kind.call? || call_node.kind.implicit_object_call?)
      return nil unless call_node.field(Syntax::Field::Block).try(&.start_byte) == start
      names = do_block_params(state, call_node)
      return nil if names.nil?
      fallback = %w(x y z w)
      params = names.map_with_index { |n, k| "${#{k + 1}:#{n || fallback[k]? || "x#{k}"}}" }
      bar = params.empty? ? "" : " |#{params.join(", ")}|"
      CompletionItem.new("do", CompletionKind::Snippet, detail: "do#{bar.gsub(/\$\{\d+:([^}]*)\}/, "\\1")} ... end",
        sort_text: "00do", insert_text: "do#{bar}\n\t$0\nend", edit_range: TextRange.new(start, offset),
        filter_text: "do", snippet: true, adjust_indent: true)
    end

    # Block parameter names for the call's resolved defs: those of the
    # first def that takes a block (`[] of String?` when it takes one of
    # unknown arity); `[]` (plain `do`) when the call is unknown; nil when
    # every resolved def has no block.
    private def do_block_params(state : FileState, call_node : Syntax::Node) : Array(String?)?
      bodies = Bodies.new(state)
      _, inf = @typing.infer_at(state, bodies, call_node.start_byte, cache: false) || return [] of String?
      body = bodies.at(call_node.start_byte) || return [] of String?
      call = body.exprs.find { |e| e.kind.call? && e.range == call_node.range } || return [] of String?
      res = inf.resolutions[call.id]? || inf.resolve_call(call)
      sites = res.candidates.empty? ? res.family.map(&.site) : res.matches.map(&.site)
      return [] of String? if sites.empty?
      # Macros may take `&block`: not knowable from the signature alone.
      return [] of String? if sites.any?(&.item.kind.macro?)
      sites.each do |s|
        names = @typing.block_param_names(s, implicit: true)
        return names if names
      end
      nil
    end

    # `name:` for parameters of the enclosing call's viable overloads that
    # are not given yet. Only at the start of an argument.
    private def named_args(start : UInt32, prefix : String) : Array(CompletionItem)
      ctx = CallContext.find(@state.text, start) || return [] of CompletionItem
      arg_text = @state.text.byte_slice(ctx.open_paren + 1, start - ctx.open_paren - 1).split(',').last? || ""
      return [] of CompletionItem unless arg_text.strip.empty?
      matches = SignatureHelp.new(@state, @typing).viable_matches(start) || return [] of CompletionItem
      items = [] of CompletionItem
      seen = Set(String).new
      matches.each do |m|
        m.site.item.signature.try &.params.each do |p|
          next unless p.kind.positional?
          name = p.call_name || next
          next unless name.starts_with?(prefix) && !ctx.given_names.includes?(name)
          next unless seen.add?(name)
          items << CompletionItem.new("#{name}:", CompletionKind::Variable, detail: p.to_s,
            sort_text: "00#{name}", insert_text: "#{name}: ")
        end
      end
      items
    end

    KEYWORDS = %w(def end if elsif else unless while until case when in then do begin rescue ensure
      return next break yield self nil true false class module struct enum lib macro require
      include extend private protected abstract alias annotation as typeof uninitialized)

    # -- helpers ------------------------------------------------------------------------

    private def word_start(text : String, offset : UInt32) : UInt32
      i = offset
      while i > 0
        c = text.byte_at(i - 1).chr
        break unless c.alphanumeric? || c == '_' || c == '@' || c == '?' || c == '!'
        i -= 1
      end
      i
    end

    # Replaces the partial word `[start, offset)` with *placeholder*.
    private def patch(text : String, start : UInt32, offset : UInt32, placeholder : String) : {String, UInt32}
      patched = Syntax::TextEdit.new(TextRange.new(start, offset), placeholder).apply(text)
      {patched, start}
    end

    # Parses the patched text and finds the node holding the placeholder.
    private def patched_node(patched : String, at : UInt32) : {Syntax::Node?, FileState?}
      tree = Syntax::Parser.new.parse(patched)
      state = FileState.new(@state.id, @state.uri, @state.revision ^ 0x8000_0000_0000_0000_u64, @state.version, tree)
      leaf = tree.root.descendant(at, at + 1)
      # The placeholder is the method name of the nearest call above it
      # (`implicit_object_call` for `&.|` and `when .|`).
      call = leaf
      depth = 0
      while (c = call) && depth < 4
        break if placeholder_call?(c, at)
        call = c.parent
        depth += 1
      end
      # No match: don't fall back to an unrelated enclosing call (for
      # `xs.map(&.|)` that was `xs.map`, offering Array's methods).
      call = nil if call && !placeholder_call?(call, at)
      {call, state}
    end

    # Is *n* a call whose method name is the placeholder at *at*? The
    # method token of an `implicit_object_call` includes its dot.
    private def placeholder_call?(n : Syntax::Node, at : UInt32) : Bool
      start = n.field(Syntax::Field::Method).try(&.start_byte) || return false
      if n.kind.implicit_object_call?
        start == at - 1
      else
        (n.kind.call? || n.kind.assign_call?) && start == at
      end
    end
  end
end
