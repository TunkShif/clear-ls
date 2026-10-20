require "./typing"
require "./analysis"
require "./signature_help"

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
    overloads : Int32 = 1

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

    def initialize(@state : FileState, @index : Workspace::Index, @typing : Typing)
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
      return [] of CompletionItem unless call_node
      recv_node = call_node.field(Syntax::Field::Receiver) || return [] of CompletionItem
      recv_t = receiver_type(state, recv_node) || return [] of CompletionItem
      method_items(recv_t, prefix)
    end

    # Type of the receiver expression in the patched copy.
    private def receiver_type(state : FileState, recv : Syntax::Node) : Types::TyId?
      bodies = Bodies.new(state)
      _, inf = @typing.infer_at(state, bodies, recv.start_byte) || return nil
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
      by_name.map do |name, (sites, depth)|
        first = sites.first?
        sig = first.try(&.item.signature)
        detail = sig ? "#{name}#{sig}" : name
        detail += "  (+#{sites.size - 1} overloads)" if sites.size > 1
        CompletionItem.new(name, first.try(&.item.kind.macro?) ? CompletionKind::Macro : CompletionKind::Method,
          detail: detail, documentation: first.try(&.item.doc),
          sort_text: "#{depth.to_s.rjust(2, '0')}#{name}", overloads: sites.size)
      end.sort_by!(&.sort_text.not_nil!).first(MAX_ITEMS)
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
    # declared (`@x : T`), from accessor macros, and `initialize(@x)` params.
    private def ivars(start : UInt32, prefix : String) : Array(CompletionItem)
      map = @typing.def_map
      ns = map.namespace_at(@state.id, start)
      class_var = prefix.starts_with?("@@")
      kind = class_var ? Items::ItemKind::ClassVar : Items::ItemKind::InstanceVar
      found = {} of String => String?
      map.ancestors(ns).each do |anc|
        info = map[anc]
        info.members.each do |name, sites|
          next unless name.starts_with?(prefix) && sites.any? { |s| s.item.kind == kind }
          found[name] ||= sites.compact_map(&.item.detail).first?
        end
        next if class_var
        info.members["initialize"]?.try &.each do |site|
          src = site_text(site) || next
          src.scan(/@(\w+)(?:\s*:\s*([^,)=]+))?/) do |m|
            name = "@#{m[1]}"
            found[name] ||= m[2]?.try(&.strip) if name.starts_with?(prefix)
          end
        end
      end
      found.map { |name, detail| CompletionItem.new(name, CompletionKind::Field, detail: detail) }
    end

    # Header text of a def (its parameter list), when it is in an open file
    # or the current file.
    private def site_text(site : Semantics::Site) : String?
      return nil unless site.file == @state.id
      r = site.item.range
      header_end = @state.text.byte_index('\n', r.start.to_i32).try(&.to_u32) || r.end
      @state.text.byte_slice(r.start, Math.min(header_end, r.end) - r.start)
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
      if state
        bodies = Bodies.new(state)
        if body = bodies.at(at)
          _, inf = @typing.infer_at(state, bodies, at) || {nil, nil}
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
      self_t = @typing.self_type(ns)
      unless @typing.table.unknown?(self_t)
        method_items(self_t, prefix).each do |i|
          items << CompletionItem.new(i.label, i.kind, i.detail, i.documentation, "1#{i.sort_text}", i.insert_text, i.overloads) if seen.add?(i.label)
        end
      end
      map.program.members.each do |name, sites|
        next unless name.starts_with?(prefix) && !name.starts_with?("self.") && !seen.includes?(name)
        # `private def` at top level is file-private.
        site = sites.find { |s| (s.item.kind.def? || s.item.kind.macro?) && (!s.item.visibility.private? || s.file == @state.id) } || next
        seen << name
        sig = site.item.signature
        kind = site.item.kind.macro? ? CompletionKind::Macro : CompletionKind::Function
        items << CompletionItem.new(name, kind, detail: sig ? "#{name}#{sig}" : nil, documentation: site.item.doc, sort_text: "2#{name}")
      end
      KEYWORDS.each do |kw|
        items << CompletionItem.new(kw, CompletionKind::Keyword, sort_text: "3#{kw}") if kw.starts_with?(prefix) && seen.add?(kw)
      end
      items.first(MAX_ITEMS)
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
      # The placeholder is the method name of the nearest call above it.
      call = leaf
      depth = 0
      while (c = call) && depth < 4
        break if (c.kind.call? || c.kind.assign_call?) && c.field(Syntax::Field::Method).try(&.start_byte) == at
        call = c.parent
        depth += 1
      end
      call = nil if call && !(call.kind.call? || call.kind.assign_call?)
      {call, state}
    end
  end
end
