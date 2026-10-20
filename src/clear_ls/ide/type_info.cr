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
      # Type at this reference (flow-sensitive within Phase 3 limits), else
      # the join of all assignments.
      expr = body.exprs.find { |e| e.range == ref.range && e.binding == b.id }
      t = expr.try { |e| inf.types[e.id]? } || inf.binding_type(b.id)
      t = inf.binding_type(b.id) if table.unknown?(t)
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
      recv_t = call.receiver.try { |r| inf.type_of(r) }
      receiver = recv_t || @typing.self_type(@typing.def_map.namespace_at(@state.id, offset))
      name = call.name || return nil
      return nil if table.unknown?(receiver) && call.receiver
      matches = table.unknown?(receiver) ? top_level(name) : inf.methods_for(receiver, name, call.children.size, !call.block.nil?)
      matches = top_level(name) if matches.empty? && call.receiver.nil?
      {call, matches, inf.types[call.id]?}
    end

    private def top_level(name : String) : Array(Types::MethodMatch)
      sites = @typing.def_map.program.members[name]? || return [] of Types::MethodMatch
      sites.select { |s| s.item.kind.def? || s.item.kind.macro? }.map do |s|
        Types::MethodMatch.new(s, Semantics::DefMap::PROGRAM, {} of String => Types::TyId)
      end
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
          decl = b.name_range
          next unless range.touches?(decl.start) && seen.add?(decl.end)
          t = inf.binding_type(b.id)
          next if table.unknown?(t)
          next if b.kind.local? && obvious?(body, b)
          hints << InlayHint.new(decl.end, ": #{table.to_s(t)}", :type)
        end
      end
      hints.sort_by!(&.offset)
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
