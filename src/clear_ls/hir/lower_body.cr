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
        return Body.new(node.range, lower_children(node, ExprKind::Seq), @exprs, @bindings, @scopes)
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
      node.field(Syntax::Field::Else).try { |e| extra << lower_children(e, ExprKind::Seq) }
      node.field(Syntax::Field::Ensure).try { |e| extra << lower_children(e, ExprKind::Seq) }
      unless extra.empty?
        root = add(ExprKind::Begin, node.range, children: [root] + extra)
      end
      Body.new(node.range, root, @exprs, @bindings, @scopes)
    end

    # -- dispatch -------------------------------------------------------------

    private def lower(node : Syntax::Node) : ExprId
      k = node.kind
      case k
      when .expressions?, .then?, .else?, .ensure?
        lower_children(node, ExprKind::Seq)
      when .identifier?
        lower_identifier(node)
      when .instance_var?
        add(ExprKind::InstanceVar, node.range, name: node.text, name_range: node.range)
      when .class_var?
        add(ExprKind::ClassVar, node.range, name: node.text, name_range: node.range)
      when .global_var?, .special_variable?
        add(ExprKind::Global, node.range, name: node.text, name_range: node.range)
      when .self_node?
        add(ExprKind::Self, node.range)
      when .constant?, .generic_instance_type?
        add(ExprKind::Const, node.range, name: node.text, name_range: node.range)
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
      when .if?, .unless?, .conditional?
        lower_if(node)
      when .modifier_if?, .modifier_unless?
        lower_children(node, k.modifier_if? ? ExprKind::If : ExprKind::Unless)
      when .case?
        lower_children(node, ExprKind::Case)
      when .while?, .until?
        lower_children(node, k.while? ? ExprKind::While : ExprKind::Until)
      when .begin?
        lower_begin(node)
      when .modifier_rescue?, .modifier_ensure?
        lower_children(node, ExprKind::Begin)
      when .return?, .break?, .next?, .yield?
        kind = {Syntax::Kind::Return => ExprKind::Return, Syntax::Kind::Break => ExprKind::Break,
                Syntax::Kind::Next => ExprKind::Next, Syntax::Kind::Yield => ExprKind::Yield}[k]
        lower_children(node, kind)
      when .and?, .or?
        lower_children(node, k.and? ? ExprKind::And : ExprKind::Or)
      when .not?
        lower_children(node, ExprKind::Not)
      when .array_node?, .hash_node?, .tuple_node?, .named_tuple?, .range_node?, .array_like?, .hash_like?
        lower_children(node, ExprKind::Collection)
      when .error?, .unknown?
        # Keep going inside recovered regions so locals still resolve.
        lower_children(node, ExprKind::Missing)
      when .macro_if?, .macro_unless?, .macro_for?, .macro_expression?, .macro_statement?,
           .macro_verbatim?, .macro_begin?
        # Macro bodies are opaque text; their locals are not modelled yet.
        add(ExprKind::Missing, node.range)
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

    private def lower_children(node : Syntax::Node, kind : ExprKind) : ExprId
      kids = [] of ExprId
      node.named_children.each do |c|
        next if c.kind.comment? || c.kind.operator?
        kids << lower(c)
      end
      add(kind, node.range, children: kids)
    end

    # -- names ----------------------------------------------------------------

    private def lower_identifier(node : Syntax::Node) : ExprId
      name = node.text
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
      add(ExprKind::Literal, node.range, children: kids)
    end

    # -- assignments ----------------------------------------------------------

    private def lower_assign(node : Syntax::Node) : ExprId
      lhs = node.fields(Syntax::Field::Lhs).select(&.named?)
      rhs = node.fields(Syntax::Field::Rhs).select(&.named?)
      # Values first: `x = x` does not see the new `x`.
      values = rhs.map { |r| lower(r) }
      targets = lhs.map { |l| lower_target(l) }
      kind = lhs.size > 1 || rhs.size > 1 ? ExprKind::MultiAssign : ExprKind::Assign
      add(kind, node.range, children: targets + values)
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
        inner = node.named_child(0)
        inner ? lower_target(inner) : add(ExprKind::Missing, node.range)
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
      receiver = node.field(Syntax::Field::Receiver).try { |r| lower(r) }
      method = node.field(Syntax::Field::Method)
      name = method.try(&.text).try(&.lchop('.'))
      args = [] of ExprId
      named = [] of {String, ExprId}
      block = nil
      if list = node.field(Syntax::Field::Arguments)
        list.named_children.each do |a|
          if a.kind.named_expr?
            value = a.named_children.find { |c| c != a.field(Syntax::Field::Name) }
            named << {a.field_text(Syntax::Field::Name) || "?", value ? lower(value) : add(ExprKind::Missing, a.range)}
          elsif a.kind.block_argument?
            block = lower_children(a, ExprKind::Block)
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
      add(ExprKind::Call, node.range, name: name, name_range: method.try(&.range),
        receiver: receiver, children: args, named_args: named, block: block)
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
      add(ExprKind::ProcLiteral, node.range, children: [inner])
    end

    # -- control flow -----------------------------------------------------------

    private def lower_if(node : Syntax::Node) : ExprId
      kids = [] of ExprId
      node.field(Syntax::Field::Cond).try { |c| kids << lower(c) }
      node.field(Syntax::Field::Then).try { |c| kids << lower(c) }
      node.field(Syntax::Field::Else).try { |c| kids << lower(c) }
      add(node.kind.unless? ? ExprKind::Unless : ExprKind::If, node.range, children: kids)
    end

    private def lower_begin(node : Syntax::Node) : ExprId
      kids = [] of ExprId
      node.field(Syntax::Field::Body).try { |b| kids << lower(b) }
      node.fields(Syntax::Field::Rescue).each { |r| kids << lower_rescue(r) if r.named? }
      node.field(Syntax::Field::Else).try { |e| kids << lower(e) }
      node.field(Syntax::Field::Ensure).try { |e| kids << lower(e) }
      add(ExprKind::Begin, node.range, children: kids)
    end

    private def lower_rescue(node : Syntax::Node) : ExprId
      if var = node.field(Syntax::Field::Variable)
        declare(var.text, BindingKind::RescueVar, node.range, var.range, node.field_text(Syntax::Field::Type))
      end
      kids = [] of ExprId
      node.field(Syntax::Field::Body).try { |b| kids << lower(b) }
      add(ExprKind::Seq, node.range, children: kids)
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
