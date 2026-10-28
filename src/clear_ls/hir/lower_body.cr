require "../syntax"
require "./body"

module ClearLS::HIR
  # Lowers one `def`/`macro`-free executable CST node into a `Body`.
  #
  # Scoping follows Crystal (checked against the compiler):
  # - parameters, then body; earlier params are visible in later defaults;
  # - `@x` / `@@x` params also introduce a local `x`;
  # - a local exists from its first assignment onwards; in `x = expr` the
  #   target is declared *after* lowering `expr`;
  # - `if`/`while`/`case`/`begin` share the enclosing scope;
  # - blocks and proc literals open a child scope: they see outer locals and
  #   reassign them, but locals first assigned inside stay block-local;
  # - block parameters shadow outer locals.
  #
  # Identifiers that are not visible locals lower to receiverless calls.
  class LowerBody
    def self.lower(node : Syntax::Node) : Body
      new.run(node)
    end

    @exprs = [] of Expr
    @bindings = [] of Binding
    @scopes = [] of Scope
    @scope = ScopeId.new(0)

    def run(node : Syntax::Node) : Body
      @scopes << Scope.new(ScopeId.new(0), ScopeKind::Def, nil, node.range)
      unless node.kind.method_def? || node.kind.abstract_method_def?
        # File or namespace body: top-level code has its own local scope;
        # nested defs/types are separate bodies.
        if node.kind.expressions? || node.parent.nil? || node.kind.class_def? || node.kind.module_def? || node.kind.struct_def?
          return Body.new(node.range, lower_children(node, ExprKind::Seq), @exprs, @bindings, @scopes)
        end
        # A single expression (a constant's value).
        root = lower(node)
        return Body.new(node.range, add(ExprKind::Seq, node.range, children: [root]), @exprs, @bindings, @scopes)
      end
      lower_params(node.field(Syntax::Field::Params), BindingKind::Param)
      root = if body = node.field(Syntax::Field::Body)
               lower(body)
             else
               add(ExprKind::Seq, node.range)
             end
      # def-level rescue/else/ensure clauses.
      extra = [] of ExprId
      node.fields(Syntax::Field::Rescue).each { |r| extra << lower_rescue(r) if r.named? }
      node.field(Syntax::Field::Else).try { |e| extra << lower(e) }
      node.field(Syntax::Field::Ensure).try { |e| extra << lower(e) }
      unless extra.empty?
        root = add(ExprKind::Begin, node.range, children: [root] + extra)
      end
      Body.new(node.range, root, @exprs, @bindings, @scopes)
    end

    # -- dispatch -------------------------------------------------------------

    private def lower(node : Syntax::Node) : ExprId
      k = node.kind
      case k
      when .expressions?, .then?
        lower_children(node, ExprKind::Seq)
      when .else?, .ensure?
        # `else`/`ensure` wrap an `expressions` body.
        add(ExprKind::Seq, node.range, syntax: node.kind, children: node.named_children.reject(&.kind.comment?).map { |c| lower(c) })
      when .identifier?
        lower_identifier(node)
      when .instance_var?
        add(ExprKind::InstanceVar, node.range, name: node.text, name_range: node.range)
      when .class_var?
        add(ExprKind::ClassVar, node.range, name: node.text, name_range: node.range)
      when .global_var?, .special_variable?
        add(ExprKind::Global, node.range, syntax: node.kind, name: node.text, name_range: node.range)
      when .self_node?
        add(ExprKind::Self, node.range)
      when .constant?, .generic_instance_type?
        add(ExprKind::Const, node.range, name: node.text, name_range: node.range)
      when .nilable_constant?
        # `Int32?` as a value: the metaclass of `Int32 | Nil`.
        add(ExprKind::Other, node.range, syntax: node.kind, type_text: node.text)
      when .integer?, .float_node?, .string_node?, .char_node?, .symbol_node?, .true_node?,
           .false_node?, .nil_node?, .regex_node?, .chained_string?, .command?, .pseudo_constant?,
           .heredoc_start?
        lower_literal(node)
      when .assign?
        lower_assign(node)
      when .op_assign?
        lower_op_assign(node)
      when .type_declaration?
        lower_type_decl(node)
      when .call?
        lower_call(node)
      when .implicit_object_call?
        lower_call(node)
      when .index_call?, .assign_call?
        lower_call(node)
      when .block?
        lower_block(node, nil)
      when .proc_node?
        lower_proc(node)
      when .method_proc?
        lower_method_proc(node)
      when .if?, .unless?, .conditional?, .elsif?, .modifier_if?, .modifier_unless?
        lower_if(node)
      when .case?, .select?
        # `select` is a `case` without subject: one `when` per action.
        lower_case(node)
      when .while?, .until?
        lower_children(node, k.while? ? ExprKind::While : ExprKind::Until)
      when .begin?
        lower_begin(node)
      when .modifier_rescue?, .modifier_ensure?
        lower_modifier_begin(node)
      when .return?, .break?, .next?, .yield?
        kind = {Syntax::Kind::Return => ExprKind::Return, Syntax::Kind::Break => ExprKind::Break,
                Syntax::Kind::Next => ExprKind::Next, Syntax::Kind::Yield => ExprKind::Yield}[k]
        # Values sit in an `argument_list`; `return a, b` returns a tuple.
        # `with x yield`: x is the yield's receiver, not an argument.
        kids = [] of ExprId
        with_recv = node.kind.yield? ? node.field(Syntax::Field::With) : nil
        recv = with_recv.try { |w| lower(w) }
        node.named_children.each do |c|
          next if c.kind.comment? || c == with_recv
          if c.kind.argument_list?
            c.named_children.each { |a| kids << lower(a) unless a.kind.comment? }
          else
            kids << lower(c)
          end
        end
        add(kind, node.range, syntax: node.kind, children: kids, receiver: recv)
      when .and?, .or?
        lower_children(node, k.and? ? ExprKind::And : ExprKind::Or)
      when .not?
        lower_children(node, ExprKind::Not)
      when .array_node?, .hash_node?, .tuple_node?, .named_tuple?, .range_node?, .array_like?, .hash_like?
        lower_collection(node)
      when .typeof?
        lower_children(node, ExprKind::TypeOf)
      when .pointerof?
        # `pointerof(x)`: the operand is evaluated for its type (and reads
        # the local); the value is `Pointer(T)`.
        kids = node.named_children.reject(&.kind.comment?).map { |c| lower(c) }
        add(ExprKind::Other, node.range, syntax: node.kind, children: kids)
      when .sizeof?, .instance_sizeof?, .alignof?, .instance_alignof?, .offsetof?
        # Type operands are not expressions; the value is an Int32.
        add(ExprKind::Other, node.range, syntax: node.kind)
      when .uninitialized_var?
        add(ExprKind::Other, node.range, syntax: node.kind, type_text: node.named_child(0).try(&.text))
      when .error?, .unknown?
        # Keep going inside recovered regions so locals still resolve.
        lower_children(node, ExprKind::Missing)
      when .macro_if?, .macro_unless?, .macro_for?, .macro_expression?, .macro_statement?,
           .macro_verbatim?, .macro_begin?
        # Macro bodies are opaque text; their locals are not modelled yet.
        add(ExprKind::Missing, node.range, syntax: node.kind)
      when .comment?, .heredoc_body?
        add(ExprKind::Other, node.range)
      when .method_def?, .abstract_method_def?, .macro_def?, .fun_def?, .lib_def?
        # Separate body / not executable here.
        add(ExprKind::Other, node.range)
      when .class_def?, .struct_def?, .module_def?, .enum_def?
        # Type bodies have their own top-level local scope.
        with_scope(node.range, ScopeKind::Def) { lower_children(node.field(Syntax::Field::Body) || node, ExprKind::Other) }
      else
        lower_children(node, ExprKind::Other)
      end
    end

    OF_KEY   = "__of__"
    OF_VALUE = "__of_value__"

    private def lower_collection(node : Syntax::Node) : ExprId
      kids = [] of ExprId
      names = [] of {String, ExprId}
      of1 = node.field_text(Syntax::Field::Of) || node.field_text(Syntax::Field::OfKey)
      of2 = node.field_text(Syntax::Field::OfValue)
      type_name = node.kind.array_like? || node.kind.hash_like? ? node.field_text(Syntax::Field::Name) : nil
      skip = [node.field(Syntax::Field::Of), node.field(Syntax::Field::OfKey), node.field(Syntax::Field::OfValue), node.field(Syntax::Field::Name)].compact
      add_elems(node, kids, names, skip, type_name)
      # `[] of typeof(x)`: the type expressions are lowered too, under
      # reserved names, so inference can type them.
      {Syntax::Field::Of => OF_KEY, Syntax::Field::OfKey => OF_KEY, Syntax::Field::OfValue => OF_VALUE}.each do |field, key|
        if (t = node.field(field)) && t.kind.typeof?
          names << {key, lower(t)} unless names.any? { |(n, _)| n == key }
        end
      end
      # Ranges with one bound: `type_text2` says which (`1..` → "begin").
      if node.kind.range_node? && kids.size == 1
        of2 = node.field(Syntax::Field::Begin) ? "begin" : "end"
      end
      add(ExprKind::Collection, node.range, syntax: node.kind, children: kids, named_args: names,
        type_text: type_name || of1, type_text2: of2, text: node.field_text(Syntax::Field::Operator))
    end

    # The grammar parses `*x` inside collection literals as `ERROR("*")`
    # followed by `x` (see tree-sitter-grammar-notes.md): rejoin them as
    # a Splat element.
    private def splat_marker?(c : Syntax::Node) : Bool
      c.kind.error? && c.named_child_count == 0 && c.text == "*"
    end

    # `*xs` where the lexer read the operand's leading `i`/`m`/`x` letters
    # as regex modifiers: ERROR("*", regex_modifier "x") then identifier
    # "s" (or nothing when the whole name is modifier letters).
    private def split_splat?(c : Syntax::Node) : Bool
      c.kind.error? && c.named_child_count == 1 && c.named_child(0).try(&.kind.regex_modifier?) || false
    end

    # Local or call named by a split splat operand: the modifier letters
    # plus an adjacent identifier.
    private def split_splat_operand(err : Syntax::Node, rest : Syntax::Node?) : {ExprId, UInt32}
      mod = err.named_child(0).not_nil!
      name = mod.text
      stop = mod.end_byte
      if rest && rest.kind.identifier? && rest.start_byte == mod.end_byte
        name += rest.text
        stop = rest.end_byte
      end
      range = TextRange.new(mod.start_byte, stop)
      expr = if b = lookup(name)
               record_ref(b, range, RefKind::Read)
               add(ExprKind::LocalRef, range, name: name, name_range: range, binding: b)
             else
               add(ExprKind::Call, range, name: name, name_range: range)
             end
      {expr, stop}
    end

    private def add_elems(node : Syntax::Node, kids : Array(ExprId), names : Array({String, ExprId}),
                          skip : Array(Syntax::Node), type_name : String?) : Nil
      splat_at = nil.as(UInt32?)
      split = nil.as(Syntax::Node?)
      children = node.named_children
      children.each_with_index do |c, ci|
        next if c.kind.comment? || c.kind.operator? || skip.includes?(c)
        if split
          # This child was consumed as the rest of a split splat operand.
          split = nil
          next if c.kind.identifier? && c.start_byte == children[ci - 1].end_byte
        end
        if splat_marker?(c)
          splat_at = c.start_byte
          next
        end
        if split_splat?(c)
          nxt = children[ci + 1]?
          operand, stop = split_splat_operand(c, nxt)
          kids << add(ExprKind::Splat, TextRange.new(c.start_byte, stop), children: [operand])
          split = c
          next
        end
        if s = splat_at
          splat_at = nil
          kids << add(ExprKind::Splat, TextRange.new(s, c.end_byte), children: [lower(c)])
          next
        end
        if c.kind.error?
          # Other recovery (`*{…}` swallowed into the ERROR): the elements
          # can't be trusted.
          kids << add(ExprKind::Missing, c.range, children: c.named_children.map { |x| lower(x) })
          next
        end
        if c.kind.named_expr?
          key = c.field(Syntax::Field::Name)
          value = c.named_children.find { |x| x != key }
          name = key.try { |k| k.kind.string_node? ? k.named_children.join(&.text) : k.text } || "?"
          names << {name, value ? lower(value) : add(ExprKind::Missing, c.range)}
        elsif c.kind.hash_entry?
          c.named_children.each { |x| kids << lower(x) unless x.kind.operator? }
        elsif (c.kind.tuple_node? || c.kind.array_node?) && type_name
          # `Set{1, 2}`: values arrive wrapped.
          add_elems(c, kids, names, [] of Syntax::Node, nil)
        else
          kids << lower(c)
        end
      end
    end

    private def lower_children(node : Syntax::Node, kind : ExprKind) : ExprId
      kids = [] of ExprId
      node.named_children.each do |c|
        next if c.kind.comment? || c.kind.operator?
        kids << lower(c)
      end
      add(kind, node.range, syntax: node.kind, children: kids)
    end

    # -- names ----------------------------------------------------------------

    # The grammar parses `x || return` / `x || return 1` with `return` as an
    # identifier / call (see docs/tree-sitter-grammar-notes.md).
    JUMP_WORDS = {"return" => ExprKind::Return, "next" => ExprKind::Next, "break" => ExprKind::Break}

    private def lower_identifier(node : Syntax::Node) : ExprId
      name = node.text
      if jump = JUMP_WORDS[name]?
        return add(jump, node.range, syntax: node.kind)
      end
      if b = lookup(name)
        record_ref(b, node.range, RefKind::Read)
        add(ExprKind::LocalRef, node.range, name: name, name_range: node.range, binding: b)
      else
        add(ExprKind::Call, node.range, name: name, name_range: node.range)
      end
    end

    private def lower_literal(node : Syntax::Node) : ExprId
      # Interpolations contain expressions.
      kids = [] of ExprId
      node.walk do |n|
        next true if n == node
        if n.kind.interpolation?
          n.named_children.each { |c| kids << lower(c) }
          next false
        end
        true
      end
      text = node.kind.integer? || node.kind.float_node? || node.kind.pseudo_constant? ? node.text : nil
      add(ExprKind::Literal, node.range, syntax: node.kind, text: text, children: kids)
    end

    # -- assignments ----------------------------------------------------------

    private def lower_assign(node : Syntax::Node) : ExprId
      lhs = node.fields(Syntax::Field::Lhs).select(&.named?)
      rhs = node.fields(Syntax::Field::Rhs).select(&.named?)
      # Values first: `x = x` does not see the new `x`.
      values = rhs.map { |r| lower(r) }
      targets = lhs.map { |l| lower_target(l) }
      kind = lhs.size > 1 || rhs.size > 1 ? ExprKind::MultiAssign : ExprKind::Assign
      # Target count in `text` (`a, b = t` has 2 targets, 1 value).
      add(kind, node.range, children: targets + values, text: kind.multi_assign? ? targets.size.to_s : nil)
    end

    private def lower_op_assign(node : Syntax::Node) : ExprId
      lhs = node.field(Syntax::Field::Lhs)
      rhs = node.field(Syntax::Field::Rhs)
      value = rhs ? lower(rhs) : add(ExprKind::Missing, node.range)
      # `x += 1` reads and writes x; `x ||= 1` may declare it.
      target = lhs ? lower_target(lhs, read_first: true) : add(ExprKind::Missing, node.range)
      add(ExprKind::OpAssign, node.range, name: node.named_children.find(&.kind.operator?).try(&.text), children: [target, value])
    end

    # Lowers an assignment target, declaring locals as needed.
    private def lower_target(node : Syntax::Node, read_first = false) : ExprId
      case node.kind
      when .identifier?
        name = node.text
        if b = lookup(name)
          record_ref(b, node.range, RefKind::Read) if read_first
          record_ref(b, node.range, RefKind::Write)
        else
          b = declare(name, BindingKind::Local, node.range, node.range, nil)
        end
        add(ExprKind::LocalRef, node.range, name: name, name_range: node.range, binding: b)
      when .splat?
        # `a, *rest = ...`: the splat target collects a tuple.
        inner = node.named_child(0)
        t = inner ? lower_target(inner) : add(ExprKind::Missing, node.range)
        add(ExprKind::Splat, node.range, children: [t])
      else
        lower(node)
      end
    end

    private def lower_type_decl(node : Syntax::Node) : ExprId
      var = node.field(Syntax::Field::Var)
      value = node.field(Syntax::Field::Value).try { |v| lower(v) }
      type = node.field_text(Syntax::Field::Type)
      kids = value ? [value] : [] of ExprId
      if var && var.kind.identifier?
        b = lookup(var.text) || declare(var.text, BindingKind::TypeDecl, node.range, var.range, type)
        record_ref(b, var.range, RefKind::Write) unless binding(b).name_range == var.range
        add(ExprKind::TypeDecl, node.range, name: var.text, name_range: var.range, binding: b, children: kids)
      else
        add(ExprKind::TypeDecl, node.range, name: var.try(&.text), name_range: var.try(&.range), children: kids)
      end
    end

    # -- calls and blocks -----------------------------------------------------

    private def lower_call(node : Syntax::Node) : ExprId
      if node.field(Syntax::Field::Receiver).nil? && (jump = JUMP_WORDS[node.field_text(Syntax::Field::Method) || ""]?)
        args = node.field(Syntax::Field::Arguments).try(&.named_children.map { |a| lower(a) }) || [] of ExprId
        return add(jump, node.range, syntax: node.kind, children: args)
      end
      receiver = node.field(Syntax::Field::Receiver).try { |r| lower(r) }
      method = node.field(Syntax::Field::Method)
      name = method.try(&.text).try(&.lchop('.'))
      if node.kind.index_call?
        close = node.children.reverse_each.find { |c| !c.named? && c.type.starts_with?(']') }
        name = "[]#{close.try(&.type.lchop(']'))}"
        name += "=" if node.parent.try { |pp| pp.kind.assign? && pp.field(Syntax::Field::Lhs) == node }
      elsif node.kind.assign_call? && name
        name += "="
      elsif node.kind.implicit_object_call? && name && (err = node.named_children.find(&.kind.error?)) &&
            err.text.strip.ends_with?('=') && !err.text.strip.in?("==", "!=", "<=", ">=", "===", "=~")
        # `&.name = v`, `&.name += v`: the grammar has no short-block
        # assignment and leaves the operator as an ERROR node. The compiler
        # calls the setter (`name=(v)`, `name=(name + v)`).
        name += "="
      end
      args = [] of ExprId
      named = [] of {String, ExprId}
      block = nil
      type_arg = nil
      if list = node.field(Syntax::Field::Arguments)
        list.named_children.each do |a|
          if TYPE_ARG_METHODS.includes?(name) && type_node?(a)
            type_arg = a.text
            next
          end
          if a.kind.named_expr?
            value = a.named_children.find { |c| c != a.field(Syntax::Field::Name) }
            key = a.field(Syntax::Field::Name)
            key_text = key.try { |k| k.kind.string_node? ? k.named_children.join(&.text) : k.text } || "?"
            named << {key_text, value ? lower(value) : add(ExprKind::Missing, a.range)}
          elsif a.kind.block_argument?
            block = lower_block_argument(a)
          elsif a.kind.out? && (v = a.named_child(0)) && v.kind.identifier?
            # `out x`: declares (or writes) the local x; the fun fills it.
            args << add(ExprKind::Other, a.range, syntax: a.kind, children: [lower_target(v)])
          elsif a.kind.splat? || a.kind.double_splat?
            inner = a.named_child(0).try { |x| lower(x) } || add(ExprKind::Missing, a.range)
            args << add(a.kind.splat? ? ExprKind::Splat : ExprKind::DoubleSplat, a.range, children: [inner])
          else
            args << lower(a)
          end
        end
      end
      # `index_call` keeps arguments as direct children.
      if node.kind.index_call?
        node.named_children.each do |c|
          next if c == node.field(Syntax::Field::Receiver) || c == method
          next if c.kind.argument_list?
          args << lower(c)
        end
      end
      if b = node.field(Syntax::Field::Block)
        block = lower_block(b, nil)
      end
      # `super()` / `previous_def(x)`: explicit (possibly empty) arguments,
      # unlike bare `super`, which forwards the def's own arguments.
      text = name.in?("super", "previous_def") && node.field(Syntax::Field::Arguments) ? "()" : nil
      add(ExprKind::Call, node.range, syntax: node.kind, name: name, name_range: method.try(&.range),
        receiver: receiver, children: args, named_args: named, block: block, type_text: type_arg, text: text)
    end

    TYPE_ARG_METHODS = %w(as as? is_a? nilable? responds_to?).to_set

    private def type_node?(n : Syntax::Node) : Bool
      n.kind.constant? || n.kind.generic_instance_type? || n.kind.union_type? || n.kind.nilable_type? ||
        n.kind.tuple_type? || n.kind.named_tuple_type? || n.kind.proc_type? || n.kind.pointer_type? ||
        n.kind.class_type? || n.kind.static_array_type?
    end

    # `&.foo` (a block with an implicit receiver) or `&proc` / `&->foo`
    # (passes a proc; no block scope, the value is evaluated once).
    private def lower_block_argument(node : Syntax::Node) : ExprId
      inner = node.named_children.find { |c| !c.kind.comment? }
      if inner && inner.kind.implicit_object_call?
        add(ExprKind::Block, node.range, syntax: Syntax::Kind::ImplicitObjectCall, children: [lower(inner)])
      else
        add(ExprKind::Block, node.range, syntax: Syntax::Kind::BlockArgument, children: inner ? [lower(inner)] : [] of ExprId)
      end
    end

    private def lower_block(node : Syntax::Node, params : Syntax::Node?) : ExprId
      with_scope(node.range) do
        lower_params(params || node.field(Syntax::Field::Params), BindingKind::BlockArg)
        body = node.field(Syntax::Field::Body).try { |b| lower(b) }
        add(ExprKind::Block, node.range, children: body ? [body] : [] of ExprId)
      end
    end

    # `->(x : T) { ... }`: params live in the block's scope.
    private def lower_proc(node : Syntax::Node) : ExprId
      params = node.field(Syntax::Field::Params)
      block = node.field(Syntax::Field::Block)
      inner = if block
                lower_block(block, params)
              else
                with_scope(node.range) do
                  lower_params(params, BindingKind::BlockArg)
                  add(ExprKind::Block, node.range)
                end
              end
      # `->(x) : R { }`: the declared return type.
      add(ExprKind::ProcLiteral, node.range, children: [inner], type_text: node.field_text(Syntax::Field::Type))
    end

    # `->foo`, `->foo(T, U)`, `->recv.foo(T)`: a proc of a method. The
    # receiver is lowered (it is evaluated); the param types go in
    # `type_text` (comma-separated).
    private def lower_method_proc(node : Syntax::Node) : ExprId
      recv = node.field(Syntax::Field::Receiver).try { |r| lower(r) }
      method = node.field(Syntax::Field::Method)
      types = node.field(Syntax::Field::Params).try(&.named_children.reject(&.kind.comment?).map(&.text)) || [] of String
      add(ExprKind::Other, node.range, syntax: node.kind, name: method.try(&.text), name_range: method.try(&.range),
        receiver: recv, type_text: types.join('\u0000'))
    end

    # -- control flow -----------------------------------------------------------

    # Always `[cond, then, else]`, with `Nop` for absent parts. Modifier
    # forms store `then` before `cond` in the CST; evaluation order is cond
    # first.
    private def lower_if(node : Syntax::Node) : ExprId
      cond = node.field(Syntax::Field::Cond).try { |c| lower(c) } || add(ExprKind::Missing, node.range)
      then_b = node.field(Syntax::Field::Then).try { |c| lower(c) } || nop(node)
      else_b = node.field(Syntax::Field::Else).try { |c| lower(c) } || nop(node)
      kind = node.kind.unless? || node.kind.modifier_unless? ? ExprKind::Unless : ExprKind::If
      add(kind, node.range, syntax: node.kind, children: [cond, then_b, else_b])
    end

    private def nop(node : Syntax::Node) : ExprId
      add(ExprKind::Nop, TextRange.new(node.end_byte, node.end_byte))
    end

    # `[subject or Nop, When..., else Seq?]`.
    private def lower_case(node : Syntax::Node) : ExprId
      kids = [(node.kind.case? ? node.field(Syntax::Field::Cond).try { |c| lower(c) } : nil) || nop(node)]
      node.named_children.each do |c|
        case c.kind
        when .when?, .in?
          conds = c.fields(Syntax::Field::Cond).select(&.named?).map { |x| lower(x) }
          body = c.field(Syntax::Field::Body).try { |b| lower(b) } || nop(c)
          kids << add(ExprKind::When, c.range, syntax: c.kind, children: conds + [body])
        when .else?
          kids << lower(c)
        end
      end
      add(ExprKind::Case, node.range, syntax: node.kind, children: kids)
    end

    # `a rescue b` → Begin[a, Rescue[b]]; `a ensure b` → Begin[a, ensure Seq[b]].
    private def lower_modifier_begin(node : Syntax::Node) : ExprId
      kids = node.named_children.reject(&.kind.comment?)
      body = kids[0]?.try { |c| lower(c) } || nop(node)
      handler = kids[1]?.try { |c| lower(c) } || nop(node)
      clause = if node.kind.modifier_rescue?
                 add(ExprKind::Rescue, node.range, syntax: Syntax::Kind::Rescue, children: [handler])
               else
                 add(ExprKind::Seq, node.range, syntax: Syntax::Kind::Ensure, children: [handler])
               end
      add(ExprKind::Begin, node.range, syntax: node.kind, children: [body, clause])
    end

    private def lower_begin(node : Syntax::Node) : ExprId
      kids = [] of ExprId
      kids << (node.field(Syntax::Field::Body).try { |b| lower(b) } || nop(node))
      node.fields(Syntax::Field::Rescue).each { |r| kids << lower_rescue(r) if r.named? }
      node.field(Syntax::Field::Else).try { |e| kids << lower(e) }
      node.field(Syntax::Field::Ensure).try { |e| kids << lower(e) }
      add(ExprKind::Begin, node.range, children: kids)
    end

    # Rescue clause; the rescued types are in `type_text` (`A | B`).
    private def lower_rescue(node : Syntax::Node) : ExprId
      type = node.field_text(Syntax::Field::Type)
      b = if var = node.field(Syntax::Field::Variable)
            declare(var.text, BindingKind::RescueVar, node.range, var.range, type)
          end
      body = node.field(Syntax::Field::Body).try { |x| lower(x) } || nop(node)
      add(ExprKind::Rescue, node.range, syntax: node.kind, binding: b, children: [body], type_text: type)
    end

    # -- parameters -----------------------------------------------------------

    private def lower_params(list : Syntax::Node?, kind : BindingKind) : Nil
      return unless list
      list.named_children.each do |p|
        # Defaults see earlier params.
        p.field(Syntax::Field::Default).try { |d| lower(d) }
        name_node = p.field(Syntax::Field::Name)
        # Unpacked block params `|(a, b)|` arrive flattened by the grammar.
        next unless name_node
        text = name_node.text
        bkind = p.kind.block_param? ? BindingKind::BlockParam : kind
        if text.starts_with?("@@") || text.starts_with?('@')
          # `def initialize(@x)` also binds local `x`.
          prefix = text.starts_with?("@@") ? 2 : 1
          local = text[prefix..]
          range = TextRange.new(name_node.start_byte + prefix, name_node.end_byte)
          declare(local, bkind, p.range, range, p.field_text(Syntax::Field::Type)) unless local.empty?
        else
          declare(text, bkind, p.range, name_node.range, p.field_text(Syntax::Field::Type))
        end
      end
    end

    # -- scopes and bindings ------------------------------------------------------

    private def with_scope(range : TextRange, kind = ScopeKind::Block, &)
      parent = @scope
      @scope = ScopeId.new(@scopes.size)
      @scopes << Scope.new(@scope, kind, kind.def? ? nil : parent, range)
      yield
    ensure
      @scope = parent.not_nil!
    end

    private def lookup(name : String) : BindingId?
      sid = @scope.as(ScopeId?)
      while id = sid
        s = @scopes[id.value]
        if b = s.bindings[name]?
          return b
        end
        sid = s.parent
      end
      nil
    end

    # Declares in the current scope (block params and block-local assigns).
    private def declare(name : String, kind : BindingKind, decl : TextRange, name_range : TextRange, restriction : String?) : BindingId
      id = BindingId.new(@bindings.size)
      b = Binding.new(id, name, kind, @scope, decl, name_range, restriction)
      b.references << Reference.new(name_range, RefKind::Decl)
      @bindings << b
      @scopes[@scope.value].bindings[name] = id
      id
    end

    private def binding(id : BindingId) : Binding
      @bindings[id.value]
    end

    private def record_ref(id : BindingId, range : TextRange, kind : RefKind) : Nil
      refs = @bindings[id.value].references
      refs << Reference.new(range, kind) unless refs.any? { |r| r.range == range && r.kind == kind }
    end

    private def add(kind : ExprKind, range : TextRange, **opts) : ExprId
      id = ExprId.new(@exprs.size)
      @exprs << Expr.new(id, kind, range, @scope, **opts)
      id
    end
  end
end
