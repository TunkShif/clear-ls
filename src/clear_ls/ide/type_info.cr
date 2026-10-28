require "./typing"
require "./alias_display"

module ClearLS::IDE
  record InlayHint, offset : UInt32, label : String, kind : Symbol

  # Which inlay hints to compute (settings `inlayHints.*`).
  record InlayHintKinds, locals : Bool = true, block_params : Bool = true, return_types : Bool = true,
    aliases : Bool = true

  # Type-aware hover, method navigation, and inlay hints.
  class TypeInfo
    # Show alias names where the type was written as one (`inlayHints.aliases`).
    property aliases = true

    def initialize(@state : FileState, @bodies : Bodies, @typing : Typing)
    end

    private def alias_display(body : HIR::Body, inf : Types::Infer) : AliasDisplay?
      return nil unless @aliases
      ns = @typing.def_map.namespace_at(@state.id, body.range.start)
      AliasDisplay.new(body, inf, @typing, ns)
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
      aliased = table.unknown?(t) ? nil : alias_display(body, inf).try do |ad|
        if expr && (body.exprs.any? { |x| (x.kind.assign? || x.kind.type_decl?) && x.children.first? == expr.id })
          ad.target(expr.id)
        else
          ad.binding(b.id, t)
        end
      end
      md = "```crystal\n#{b.name}#{(aliased || ty) ? " : #{aliased || ty}" : ""}\n```\n\n#{KIND_NAMES[b.kind]}"
      md += "\n\n= `#{ty}`" if aliased && aliased != ty
      # `x : T = v`: the flow type above, the declaration as a note when it
      # differs (decision 3).
      if b.kind.type_decl? && (r = b.restriction) && ty && ty != r
        md += " (declared `#{r}`)"
      end
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
      # No declaration fits but the call is typed: a compiler-generated
      # method (number operators from `{% for %}` in primitives.cr). The
      # family (`Number#+()` unary) would be misleading.
      if res.candidates.empty? && (rt = inf.types[call.id]?) && !table.unknown?(rt)
        matches = [] of Types::MethodMatch
      end
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
        io << " (type from the compiler at the last check)" if owner && compiler_ivar?(map, owner, name)
      end
      {md, node.range}
    end

    private def compiler_ivar?(map : Semantics::DefMap, owner : Semantics::TypeId, name : String) : Bool
      return false if map.ancestors(owner).any? { |a| map[a].members[name]?.try &.any? { |s| !s.item.origin.compiler? && !s.item.origin.assigned_or_param? } }
      map.ancestors(owner).any? { |a| map[a].members[name]?.try &.any?(&.item.origin.compiler?) }
    end

    # Definition of `@x` / `@@x` at *offset*: the sites of the nearest
    # ancestor that has any, strongest category first: a declaration
    # (`@x : T`, `@x = v` in the type body), an accessor macro (its name),
    # `def ...(@x)` params, else every `@x = v` assignment in defs.
    # Compiler-only ivars point at the type (no better location).
    def ivar_definitions(offset : UInt32) : Array(Semantics::Site)
      node = @state.tree.root.descendant(offset, offset, named: true) || return [] of Semantics::Site
      return [] of Semantics::Site unless node.kind.instance_var? || node.kind.class_var?
      ivar_sites(node.text, node.kind.class_var?, @typing.def_map.namespace_at(@state.id, offset))
    end

    def ivar_sites(name : String, cvar : Bool, ns : Semantics::TypeId) : Array(Semantics::Site)
      map = @typing.def_map
      return [] of Semantics::Site if ns == Semantics::DefMap::PROGRAM
      kind = cvar ? Items::ItemKind::ClassVar : Items::ItemKind::InstanceVar
      map.ancestors(ns).each do |anc|
        sites = (map[anc].members[name]? || [] of Semantics::Site).select(&.item.kind.==(kind))
        next if sites.empty?
        {% for cat in [:source, :macro, :param, :assigned] %}
          picked = sites.select { |s| ivar_category(s) == {{cat}} }
          return picked unless picked.empty?
        {% end %}
        return sites # compiler facts
      end
      [] of Semantics::Site
    end

    private def ivar_category(s : Semantics::Site) : Symbol
      case s.item.origin
      in .source?   then :source
      in .macro?    then :macro
      in .param?    then :param
      in .assigned? then :assigned
      in .compiler? then :compiler
      end
    end

    # Restriction text of a declaration when it does not parse to a type.
    private def declared_text(owner : Semantics::TypeId?, name : String, cvar : Bool) : String?
      owner || return nil
      kind = cvar ? Items::ItemKind::ClassVar : Items::ItemKind::InstanceVar
      @typing.def_map.lookup_member(owner, name).find(&.item.kind.==(kind)).try(&.item.detail)
    end

    # `self` in a body: the instance type, or the metaclass inside
    # `def self.foo` / at class-body level. (`self` as a def receiver is
    # `def_hover`.)
    def self_hover(offset : UInt32) : {String, TextRange}?
      node = @state.tree.root.descendant(offset, offset, named: true) || return nil
      return nil unless node.kind.self_node?
      parent = node.parent
      return nil if parent && (parent.kind.method_def? || parent.kind.abstract_method_def?) &&
                    parent.fields(Syntax::Field::ClassNode).includes?(node)
      t = nil.as(Types::TyId?)
      if hit = @typing.infer_at(@state, @bodies, offset)
        body, inf = hit
        e = body.exprs.find { |x| x.kind.self? && x.range == node.range }
        t = e.try { |x| inf.types[x.id]? }
      end
      map = @typing.def_map
      ns = map.namespace_at(@state.id, offset)
      if t.nil? || table.unknown?(t)
        # Class bodies (no def): self is the type itself.
        t = ns == Semantics::DefMap::PROGRAM ? nil : table.metaclass(@typing.self_type(ns))
      end
      ty = t && !table.unknown?(t) ? table.to_s(t) : nil
      md = String.build do |io|
        io << "```crystal
self"
        io << " : " << ty if ty
        io << "
```"
        io << "

top-level `self` (the program)" if ns == Semantics::DefMap::PROGRAM
        if t && table[t].kind.metaclass?
          io << "

the class itself (class method or type body)"
        elsif ty
          io << "

the current instance"
        end
      end
      {md, node.range}
    end

    LITERAL_KINDS = [Syntax::Kind::Integer, Syntax::Kind::FloatNode, Syntax::Kind::CharNode,
                     Syntax::Kind::SymbolNode, Syntax::Kind::RegexNode, Syntax::Kind::NilNode,
                     Syntax::Kind::TrueNode, Syntax::Kind::FalseNode]

    # Number/char/symbol/regex/nil/bool literals: the literal's type
    # (`1_u8` → UInt8). Strings are left alone (hovering text is noise).
    def literal_hover(offset : UInt32) : {String, TextRange}?
      node = @state.tree.root.descendant(offset, offset, named: true) || return nil
      return nil unless LITERAL_KINDS.includes?(node.kind)
      t = nil.as(Types::TyId?)
      if hit = @typing.infer_at(@state, @bodies, offset)
        body, inf = hit
        t = body.exprs.find { |e| e.kind.literal? && e.range == node.range }.try { |e| inf.types[e.id]? }
      end
      t ||= Types::Infer.value_text_type(node.text, table, Semantics::DefMap::PROGRAM)
      return nil if table.unknown?(t)
      {"```crystal\n#{table.to_s(t)}\n```\n\nliteral", node.range}
    end

    # `{name: v}` key: the value's type. `x += v` operator: the method it
    # calls and the result.
    def key_or_op_hover(offset : UInt32) : {String, TextRange}?
      node = @state.tree.root.descendant(offset, offset, named: true) || return nil
      parent = node.parent || return nil
      hit = @typing.infer_at(@state, @bodies, offset) || return nil
      body, inf = hit
      if parent.kind.named_expr? && parent.field(Syntax::Field::Name) == node && parent.parent.try(&.kind.named_tuple?)
        value = parent.named_children.find { |c| c != node } || return nil
        e = body.exprs.find { |x| x.range == value.range && !x.kind.seq? } || return nil
        t = inf.types[e.id]? || return nil
        return nil if table.unknown?(t)
        return {"```crystal\n#{node.text.rchop(':')} : #{table.to_s(t)}\n```\n\nnamed tuple key", node.range}
      end
      if node.kind.operator? && parent.kind.op_assign?
        e = body.exprs.find { |x| x.kind.op_assign? && x.range == parent.range } || return nil
        t = inf.types[e.id]? || return nil
        return nil if table.unknown?(t)
        return {"```crystal\n#{node.text} : #{table.to_s(t)}\n```\n\ncompound assignment", node.range}
      end
      nil
    end

    # `getter x : T` & co. on the macro name: the methods it generates
    # (from the item tree), then the macro's own documentation.
    # On an accessor macro (`property`) or the name it declares (`name`
    # in `property name = "x"`): the generated methods.
    def accessor_macro_hover(offset : UInt32) : {String, TextRange}?
      node = @state.tree.root.descendant(offset, offset, named: true) || return nil
      map = @typing.def_map
      ns = map.namespace_at(@state.id, offset)
      generated = [] of Items::Item
      call = node.parent
      if call && call.kind.call? && call.field(Syntax::Field::Method) == node && call.field(Syntax::Field::Receiver).nil?
        map[ns].each_member_site do |s|
          next unless s.file == @state.id && s.item.origin.macro? && s.item.range == call.range
          generated << s.item if s.item.kind.def?
        end
        macro_name = node.text
      else
        map[ns].each_member_site do |s|
          next unless s.file == @state.id && s.item.origin.macro? && s.item.kind.def? && s.item.name_range == node.range
          generated << s.item
        end
        call = node
        while call && !call.kind.call?
          call = call.parent
        end
        macro_name = call.try(&.field_text(Syntax::Field::Method)) || "a macro"
      end
      return nil if generated.empty?
      owner = map[ns].full_name
      md = String.build do |io|
        io << "```crystal\n"
        generated.sort_by!(&.name).each do |it|
          io << "def " << owner << (it.signature.try(&.receiver) ? "." : "#") << it.name << it.signature << '\n'
        end
        io << "```\n\ngenerated by `" << macro_name << '`'
      end
      {md, node.range}
    end

    # Params of bodyless defs (`abstract def`, `macro`, `fun`) have no HIR
    # body; show the declared restriction.
    def decl_param_hover(offset : UInt32) : {String, TextRange}?
      node = @state.tree.root.descendant(offset, offset, named: true) || return nil
      param = node.parent || return nil
      return nil unless param.kind.param? && param.field(Syntax::Field::Name) == node
      d = param.parent.try(&.parent) || return nil
      return nil unless d.kind.abstract_method_def? || d.kind.macro_def? || d.kind.fun_def?
      type = param.field_text(Syntax::Field::Type)
      kind = d.kind.macro_def? ? "macro parameter" : "parameter"
      {"```crystal\n#{node.text}#{type ? " : #{type}" : ""}\n```\n\n#{kind}", node.range}
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
        if item.kind.def? && item.signature.try(&.return_type).nil? && (rt = inferred_return(def_node))
          io << "\n\n→ `" << rt << "` (inferred)"
        end
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
      if matches.empty?
        # Compiler-generated methods (`Proc#call`, enum `red?`, number
        # primitives): no declaration, but the inferred result type.
        return nil unless ret && !table.unknown?(ret)
        recv = call.receiver.try { |r| @typing.infer_at(@state, @bodies, offset).try { |(_, inf)| inf.type_of(r) } }
        md = String.build do |io|
          io << "```crystal
"
          io << table.to_s(recv) << '#' if recv && !table.unknown?(recv)
          io << call.name << " : " << table.to_s(ret) << "\n```\n\nbuilt-in (no source declaration)"
        end
        return {md, call.name_range.not_nil!}
      end
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
        if matches.first.site.item.origin.compiler?
          io << "\n\ngenerated by a macro (reported by the compiler at the last check)"
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
    # Return type of an unannotated def's body, inferred with its declared
    # param types (unrestricted params unknown); nil when unknown.
    def inferred_return(def_node : Syntax::Node) : String?
      body, inf = @typing.infer_at(@state, @bodies, def_node.start_byte + 1) || return nil
      return nil unless body.range == def_node.range
      t = inf.return_type
      return nil if table.unknown?(t)
      table.to_s(t)
    end

    def inlay_hints(range : TextRange, kinds = InlayHintKinds.new) : Array(InlayHint)
      hints = [] of InlayHint
      seen = Set(UInt32).new
      return_hints(range, hints) if kinds.return_types
      return hints unless kinds.locals || kinds.block_params
      each_body_in(range) do |body, inf|
        ad = kinds.aliases ? alias_display(body, inf) : nil
        body.bindings.each do |b|
          next unless (b.kind.local? && kinds.locals) || (b.kind.block_arg? && kinds.block_params)
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
          # Assignments: the assigned value's spelling; block args: what
          # their call's receiver carries.
          label = (decl_e ? ad.try(&.target(decl_e.id)) : ad.try(&.binding(b.id, t))) || table.to_s(t)
          hints << InlayHint.new(decl.end, ": #{label}", :type)
        end
      end
      hints.sort_by!(&.offset)
    end

    # `def foo(x)` → ` : Int32` after the param list, for defs without a
    # return type whose body's type is known.
    private def return_hints(range : TextRange, hints : Array(InlayHint)) : Nil
      @state.tree.root.walk do |n|
        next false if n.end_byte < range.start || n.start_byte > range.end
        if n.kind.method_def?
          if n.field(Syntax::Field::Type).nil? && (name = n.field(Syntax::Field::Name)) && name.text != "initialize"
            anchor = header_end(n, name)
            if range.touches?(anchor) && (rt = inferred_return(n))
              hints << InlayHint.new(anchor, " : #{rt}", :type)
            end
          end
          next false
        end
        true
      end
    end

    # End of a def header without its return type: after the `)` that
    # closes the params (the `param_list` node stops before it), else
    # after the name.
    private def header_end(def_node : Syntax::Node, name : Syntax::Node) : UInt32
      params = def_node.field(Syntax::Field::Params) || return name.end_byte
      sib = params.next_sibling
      sib && sib.type == ")" ? sib.end_byte : params.end_byte
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
