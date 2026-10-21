require "./typing"

module ClearLS::IDE
  record InlayHint, offset : UInt32, label : String, kind : Symbol

  # Type-aware hover, method navigation, and inlay hints.
  class TypeInfo
    def initialize(@state : FileState, @bodies : Bodies, @typing : Typing)
    end

    private def table : Types::TypeTable
      @typing.table
    end

    # Local under the cursor with its inferred type at that reference.
    def local_hover(offset : UInt32) : {String, TextRange}?
      hit = Locals.new(@state, @bodies).binding_at(offset) || return nil
      body, b, ref = hit
      _, inf = @typing.infer_at(@state, @bodies, offset) || return nil
      # Flow-sensitive: a read shows the type at its program point, a write
      # the assigned type; params and block args (no expression) show their
      # declared/joined type.
      expr = body.exprs.find { |e| e.range == ref.range && e.binding == b.id }
      t = expr.try { |e| inf.types[e.id]? } || inf.binding_type(b.id)
      t = inf.binding_type(b.id) if table.unknown?(t) && !(ref.kind.read? && expr)
      ty = table.unknown?(t) ? b.restriction : table.to_s(t)
      md = "```crystal\n#{b.name}#{ty ? " : #{ty}" : ""}\n```\n\n#{KIND_NAMES[b.kind]}"
      {md, ref.range}
    end

    KIND_NAMES = {
      HIR::BindingKind::Param      => "parameter",
      HIR::BindingKind::BlockParam => "block parameter",
      HIR::BindingKind::BlockArg   => "block argument",
      HIR::BindingKind::Local      => "local variable",
      HIR::BindingKind::RescueVar  => "rescued exception",
      HIR::BindingKind::TypeDecl   => "local variable",
      HIR::BindingKind::MacroVar   => "macro variable",
    }

    # Call whose method name is under the cursor, with its candidates.
    def call_at(offset : UInt32) : {HIR::Expr, Array(Types::MethodMatch), Types::TyId?}?
      body = @bodies.at(offset) || return nil
      call = body.exprs.find do |e|
        e.kind.call? && (nr = e.name_range) && nr.start <= offset && offset <= nr.end
      end
      call || return nil
      _, inf = @typing.infer_at(@state, @bodies, offset) || return nil
      call.name || return nil
      res = inf.resolutions[call.id]? || inf.resolve_call(call)
      # Viable overloads; the whole family when none fits (unfinished or
      # wrong calls), so navigation still works.
      matches = res.candidates.empty? ? res.family : res.matches
      {call, matches, inf.types[call.id]?}
    end

    # `@x` / `@@x` anywhere in the file: declared type from the owner and
    # its ancestors (`@x : T`, accessors, `initialize(@x : T)`), else the
    # type inferred at this expression.
    def var_hover(offset : UInt32) : {String, TextRange}?
      node = @state.tree.root.descendant(offset, offset, named: true) || return nil
      return nil unless node.kind.instance_var? || node.kind.class_var?
      name = node.text
      cvar = node.kind.class_var?
      map = @typing.def_map
      ns = map.namespace_at(@state.id, offset)
      owner = ns == Semantics::DefMap::PROGRAM ? nil : ns
      ctx = Types::DefContext.new(ns, @typing.self_type(ns), owner.try { |o| map[o].type_params } || [] of String)
      t = Types::Infer.ivar_type(map, table, owner, name, cvar, ctx)
      if table.unknown?(t) && (hit = @typing.infer_at(@state, @bodies, offset))
        body, inf = hit
        body.exprs.each do |e|
          next unless e.range == node.range
          et = inf.types[e.id]? || next
          t = et unless table.unknown?(et)
        end
      end
      ty = table.unknown?(t) ? declared_text(owner, name, cvar) : table.to_s(t)
      kind = cvar ? "class variable" : "instance variable"
      owner_name = owner.try { |o| map[o].full_name }
      md = String.build do |io|
        io << "```crystal
" << name
        io << " : " << ty if ty
        io << "
```

" << kind
        io << " of `" << owner_name << '`' if owner_name
      end
      {md, node.range}
    end

    # Restriction text of a declaration when it does not parse to a type.
    private def declared_text(owner : Semantics::TypeId?, name : String, cvar : Bool) : String?
      owner || return nil
      kind = cvar ? Items::ItemKind::ClassVar : Items::ItemKind::InstanceVar
      @typing.def_map.lookup_member(owner, name).find(&.item.kind.==(kind)).try(&.item.detail)
    end

    # On a def's name or its `self.` receiver: the declaration's signature.
    def def_hover(offset : UInt32) : {String, TextRange}?
      node = @state.tree.root.descendant(offset, offset, named: true) || return nil
      def_node = node.parent || return nil
      return nil unless def_node.kind.method_def? || def_node.kind.abstract_method_def? || def_node.kind.macro_def?
      name_node = def_node.field(Syntax::Field::Name)
      recv_node = def_node.fields(Syntax::Field::ClassNode).find(&.named?)
      return nil unless node == name_node || node == recv_node
      map = @typing.def_map
      ns = map.namespace_at(@state.id, def_node.start_byte)
      site = map[ns].members.each_value.flat_map(&.itself).find do |s|
        s.file == @state.id && s.item.range.start == def_node.start_byte
      end || return nil
      item = site.item
      owner = map[ns].full_name
      md = String.build do |io|
        io << "```crystal
"
        io << item.visibility.to_s.downcase << ' ' unless item.visibility.public?
        io << (item.kind.macro? ? "macro " : "def ")
        io << owner << (item.signature.try(&.receiver) ? "." : "#") unless owner.empty?
        io << item.name << item.signature << "
```"
        if node == recv_node && !owner.empty?
          io << "

class method: `self` is `" << owner << ".class`"
        end
        if doc = item.doc
          io << "

" << doc
        end
      end
      {md, node.range}
    end

    def method_hover(offset : UInt32) : {String, TextRange}?
      call, matches, ret = call_at(offset) || return nil
      return nil if matches.empty?
      map = @typing.def_map
      md = String.build do |io|
        io << "```crystal\n"
        matches.first(5).each do |m|
          owner = map[m.owner].full_name
          sig = m.site.item.signature
          io << "def "
          io << owner << (sig.try(&.receiver) ? "." : "#") unless owner.empty?
          io << m.site.item.name << sig << '\n'
        end
        io << "# … #{matches.size - 5} more overloads\n" if matches.size > 5
        io << "```"
        if ret && !table.unknown?(ret)
          io << "\n\n→ `" << table.to_s(ret) << '`'
        end
        if doc = matches.first.site.item.doc
          io << "\n\n" << doc
        end
      end
      {md, call.name_range.not_nil!}
    end

    def method_definitions(offset : UInt32) : Array(Semantics::Site)
      _, matches, _ = call_at(offset) || return [] of Semantics::Site
      matches.map(&.site).uniq
    end

    # `: Type` after locals at their declaration, when inferred and not
    # obvious from a literal or `.new` on the right-hand side.
    def inlay_hints(range : TextRange) : Array(InlayHint)
      hints = [] of InlayHint
      seen = Set(UInt32).new
      each_body_in(range) do |body, inf|
        body.bindings.each do |b|
          next unless b.kind.local? || b.kind.block_arg?
          # Class/module bodies: `getter x = ...` arguments look like locals.
          next if body.scope(b.scope).kind.def? && b.scope.value != 0
          next if in_type_body?(b.name_range.start)
          decl = b.name_range
          next unless range.touches?(decl.start) && seen.add?(decl.end)
          # The type assigned at the declaration, not the join of all writes
          # (`x = 1; x = "s"` hints `x : Int32`).
          decl_e = body.exprs.find { |e| e.range == decl && e.binding == b.id && e.kind.local_ref? }
          t = decl_e.try { |e| inf.types[e.id]? } || inf.binding_type(b.id)
          next if table.unknown?(t)
          next if b.kind.local? && obvious?(body, b)
          hints << InlayHint.new(decl.end, ": #{table.to_s(t)}", :type)
        end
      end
      hints.sort_by!(&.offset)
    end

    private def in_type_body?(offset : UInt32) : Bool
      node = @state.tree.root.descendant(offset, offset + 1)
      while n = node
        return false if n.kind.method_def? || n.kind.block?
        return true if n.kind.class_def? || n.kind.struct_def? || n.kind.module_def?
        node = n.parent
      end
      false
    end

    # The value is a literal or `T.new(...)`, so the type is visible.
    private def obvious?(body : HIR::Body, b : HIR::Binding) : Bool
      assign = body.exprs.find do |e|
        (e.kind.assign? || e.kind.type_decl?) && e.children.first?.try { |c| body.expr(c).binding == b.id }
      end
      return true if body.exprs.any? { |e| e.kind.type_decl? && e.binding == b.id }
      value = assign.try { |a| a.children[1]?.try { |v| body.expr(v) } } || return false
      return true if value.kind.literal?
      value.kind.call? && value.name == "new" && value.receiver.try { |r| body.expr(r).kind.const? } || false
    end

    private def each_body_in(range : TextRange, & : HIR::Body, Types::Infer ->) : Nil
      starts = [] of UInt32
      root = @state.tree.root
      root.walk do |n|
        next false if n.end_byte < range.start || n.start_byte > range.end
        starts << n.start_byte + 1 if n.kind.method_def?
        true
      end
      starts << 0_u32
      done = Set(UInt32).new
      starts.each do |s|
        body, inf = @typing.infer_at(@state, @bodies, s) || next
        next unless done.add?(body.range.start)
        yield body, inf
      end
    end
  end
end
