require "../syntax"
require "./item"

module ClearLS::Items
  # Lowers a file's CST into an `ItemTree`.
  #
  # Handles:
  # - declarations nested in `visibility_modifier`, annotations, doc comments;
  # - `{% if/unless/elsif/else %}` blocks: their opaque `macro_content` is
  #   reparsed with included ranges and lowered with the guarding condition;
  # - declarations recovered inside `ERROR` nodes (the grammar turns e.g.
  #   `module M` into `ERROR (constant) ...` around half-typed code);
  # - known declarative macros: getter/setter/property families, record,
  #   class_getter & co.
  class Lower
    ACCESSORS = {
      "getter"         => {getter: true, setter: false, suffix: ""},
      "getter?"        => {getter: true, setter: false, suffix: "?"},
      "getter!"        => {getter: true, setter: false, suffix: "!"},
      "setter"         => {getter: false, setter: true, suffix: ""},
      "property"       => {getter: true, setter: true, suffix: ""},
      "property?"      => {getter: true, setter: true, suffix: "?"},
      "property!"      => {getter: true, setter: true, suffix: "!"},
      "class_getter"   => {getter: true, setter: false, suffix: ""},
      "class_getter?"  => {getter: true, setter: false, suffix: "?"},
      "class_getter!"  => {getter: true, setter: false, suffix: "!"},
      "class_setter"   => {getter: false, setter: true, suffix: ""},
      "class_property" => {getter: true, setter: true, suffix: ""},
      "class_property?" => {getter: true, setter: true, suffix: "?"},
      "class_property!" => {getter: true, setter: true, suffix: "!"},
    }

    # Kinds that open a namespace, with the item kind inside and outside `lib`.
    TYPE_DEFS = {
      Syntax::Kind::ModuleDef     => ItemKind::Module,
      Syntax::Kind::ClassDef      => ItemKind::Class,
      Syntax::Kind::StructDef     => ItemKind::Struct,
      Syntax::Kind::EnumDef       => ItemKind::Enum,
      Syntax::Kind::LibDef        => ItemKind::Lib,
      Syntax::Kind::AnnotationDef => ItemKind::Annotation,
      Syntax::Kind::CStructDef    => ItemKind::CStruct,
      Syntax::Kind::UnionDef      => ItemKind::CUnion,
    }

    ERROR_KEYWORDS = {
      "module" => ItemKind::Module, "class" => ItemKind::Class,
      "struct" => ItemKind::Struct, "enum" => ItemKind::Enum, "lib" => ItemKind::Lib,
    }

    def self.lower(tree : Syntax::Tree) : ItemTree
      new(tree).run
    end

    @requires = [] of Require
    @recovered = false
    @conds = [] of Cond
    @mixins = [] of TopLevelMixin
    @parser : Syntax::Parser? = nil

    def initialize(@tree : Syntax::Tree)
    end

    def run : ItemTree
      items = [] of Item
      lower_top(@tree.root, items)
      ItemTree.new(items, @requires, @recovered, @mixins)
    end

    # The file's top level. `{% skip_file %}` (compiler macro: the rest
    # of the file is not read) guards every later statement with the
    # negation of its condition: `{% skip_file if flag?(:win32) %}`,
    # `{% unless flag?(:x) %}{% skip_file %}{% end %}`. An unconditional
    # one ends the file. An unknown condition keeps the rest (as before).
    private def lower_top(root : Syntax::Node, dest : Array(Item)) : Nil
      pushed = 0
      pending_annotations = [] of String
      root.named_children.each do |node|
        if node.kind.annotation_node?
          pending_annotations << annotation_text(node)
          next
        end
        next if node.kind.comment?
        start = dest.size
        lower_stmt(node, dest, nil, Visibility::Public)
        unless pending_annotations.empty?
          dest[start..].each(&.annotations.concat(pending_annotations))
          pending_annotations = [] of String
        end
        if skip = skip_file_cond(node)
          break if skip.is_a?(Bool)
          @conds.push(Cond::Not.new(skip))
          pushed += 1
        end
      end
    ensure
      pushed.try &.times { @conds.pop }
    end

    # When *node* skips the rest of the file: `true` always, else under
    # which condition. Nil when it is no `skip_file`.
    private def skip_file_cond(node : Syntax::Node) : Cond | Bool | Nil
      case node.kind
      when .macro_statement?
        expr = node.named_child(0)
        expr = expr.named_child(0) if expr && expr.kind.expressions? && expr.named_child_count == 1
        return nil unless expr
        return true if skip_file_call?(expr)
        if (expr.kind.modifier_if? || expr.kind.modifier_unless?) && (t = expr.field(Syntax::Field::Then)) && skip_file_call?(t)
          c = expr.field(Syntax::Field::Cond).try { |n| parse_cond(n) } || Cond::Unknown.new("?")
          return expr.kind.modifier_unless? ? Cond::Not.new(c) : c
        end
      when .macro_if?, .macro_unless?
        c = node.field(Syntax::Field::Cond).try { |n| parse_cond(n) } || Cond::Unknown.new("?")
        c = Cond::Not.new(c) if node.kind.macro_unless?
        if node.field(Syntax::Field::Then).try { |b| skips?(b) }
          return c
        end
        alt = node.field(Syntax::Field::Else)
        if alt && !alt.kind.macro_elsif? && alt.field(Syntax::Field::Body).try { |b| skips?(b) }
          return Cond::Not.new(c)
        end
      end
      nil
    end

    # A macro body holding a bare `{% skip_file %}`.
    private def skips?(body : Syntax::Node) : Bool
      body.named_children.any? { |c| c.kind.macro_statement? && skip_file_cond(c) == true }
    end

    private def skip_file_call?(node : Syntax::Node) : Bool
      (node.kind.identifier? && node.text == "skip_file") ||
        (node.kind.call? && node.field_text(Syntax::Field::Method) == "skip_file" && node.field(Syntax::Field::Receiver).nil?)
    end

    # Lowers the statements of *body* into *dest*. *owner* is the enclosing
    # item kind (nil at top level), which changes meaning of some nodes.
    private def lower_body(body : Syntax::Node, dest : Array(Item), owner : Item?) : Nil
      pending_annotations = [] of String
      body.named_children.each do |node|
        if node.kind.annotation_node?
          pending_annotations << annotation_text(node)
          next
        end
        next if node.kind.comment?
        start = dest.size
        lower_stmt(node, dest, owner, Visibility::Public)
        unless pending_annotations.empty?
          dest[start..].each(&.annotations.concat(pending_annotations))
          pending_annotations = [] of String
        end
      end
    end

    private def lower_stmt(node : Syntax::Node, dest : Array(Item), owner : Item?, vis : Visibility) : Nil
      kind = node.kind
      case kind
      when .visibility_modifier?
        v = case node.field_text(Syntax::Field::Visibility)
            when "private"   then Visibility::Private
            when "protected" then Visibility::Protected
            else                  Visibility::Public
            end
        node.named_children.each do |child|
          lower_stmt(child, dest, owner, v) unless child.kind.private? || child.kind.protected?
        end
      when .module_def?, .class_def?, .struct_def?, .enum_def?, .lib_def?,
           .annotation_def?, .c_struct_def?, .union_def?
        dest << lower_type(node, TYPE_DEFS[kind], vis, owner)
      when .method_def?, .abstract_method_def?
        d = lower_def(node, ItemKind::Def, vis, is_abstract: kind.abstract_method_def?)
        dest << d
        if owner && (sig = d.signature) && kind.method_def?
          name = sig.receiver ? "self.#{d.name}" : d.name
          dest.concat(assigned_ivars(node, sig, name))
        end
        # Crystal forbids `def` inside `def`, so one there means error
        # recovery attached following defs to an unterminated body.
        if node.has_error? || @recovered
          node.field(Syntax::Field::Body).try &.named_children.each do |stmt|
            lower_stmt(stmt, dest, owner, Visibility::Public) if stmt.kind.method_def? || stmt.kind.abstract_method_def?
          end
        end
      when .macro_def?
        dest << lower_def(node, ItemKind::Macro, vis, is_abstract: false)
      when .fun_def?
        dest << lower_def(node, ItemKind::Fun, vis, is_abstract: false)
      when .const_assign?
        if lhs = node.field(Syntax::Field::Lhs)
          dest << item(ItemKind::Constant, lhs.text, node, lhs, vis, detail: node.field_text(Syntax::Field::Rhs))
        end
      when .constant?
        # Bare constant in an enum body is a member.
        if owner.try(&.kind.enum?)
          dest << item(ItemKind::Constant, node.text, node, node, vis)
        end
      when .alias_node?
        if name = node.field(Syntax::Field::Name)
          dest << item(ItemKind::Alias, name.text, node, name, vis, detail: node.field_text(Syntax::Field::Type))
        end
      when .type_def?
        if name = node.field(Syntax::Field::Name)
          dest << item(ItemKind::TypeDef, name.text, node, name, vis, detail: node.field_text(Syntax::Field::Type))
        end
      when .global_var?
        if name = node.field(Syntax::Field::Name)
          dest << item(ItemKind::CVar, name.text, node, name, vis, detail: node.field_text(Syntax::Field::Type))
        end
      when .c_struct_fields?, .union_fields?
        type = node.field_text(Syntax::Field::Type)
        node.fields(Syntax::Field::Name).each do |name|
          next unless name.named?
          dest << item(ItemKind::CField, name.text, node, name, vis, detail: type)
        end
      when .type_declaration?
        var = node.field(Syntax::Field::Var)
        if var && owner && (var.kind.instance_var? || var.kind.class_var?)
          k = var.kind.instance_var? ? ItemKind::InstanceVar : ItemKind::ClassVar
          dest << item(k, var.text, node, var, vis, detail: node.field_text(Syntax::Field::Type))
        end
      when .assign?
        # `@x = 1` / `@@x = 0` in a type body: an ivar/cvar with an initial
        # value (typed from the value text later).
        lhs = node.field(Syntax::Field::Lhs)
        if lhs && owner && (lhs.kind.instance_var? || lhs.kind.class_var?)
          k = lhs.kind.instance_var? ? ItemKind::InstanceVar : ItemKind::ClassVar
          dest << item(k, lhs.text, node, lhs, vis, detail: node.field_text(Syntax::Field::Rhs))
        end
      when .include?, .extend?
        if target = node.named_children.find { |c| !c.kind.error? && !c.kind.comment? }
          if owner
            (kind.include? ? owner.includes : owner.extends) << target.text
          else
            @mixins << TopLevelMixin.new(target.text, kind.extend?, node.range, @conds.dup)
          end
        end
      when .require?
        if str = node.named_child(0)
          @requires << Require.new(string_value(str), node.range, @conds.dup)
        end
      when .call?
        lower_macro_call(node, dest, owner, vis)
      when .macro_if?, .macro_unless?
        lower_macro_if(node, dest, owner, vis)
      when .error?
        @recovered = true
        lower_error(node, dest, owner, vis)
      when .expressions?
        node.named_children.each { |c| lower_stmt(c, dest, owner, vis) }
      end
    end

    # -- types --------------------------------------------------------------

    private def lower_type(node : Syntax::Node, kind : ItemKind, vis : Visibility, owner : Item?) : Item
      name_node = node.field(Syntax::Field::Name)
      path_text = name_node.try(&.text) || ""
      params = [] of String
      splat = nil
      if name_node && name_node.kind.generic_type?
        path_text = name_node.named_child(0).try(&.text) || ""
        name_node.field(Syntax::Field::Params).try &.named_children.each_with_index do |p, i|
          if p.kind.splat?
            splat = i
            params << (p.named_child(0).try(&.text) || "")
          else
            params << p.text
          end
        end
      end
      global = path_text.starts_with?("::")
      path = path_text.lchop("::").split("::").reject(&.empty?)
      path = ["?"] if path.empty?
      is_abstract = node.children.any? { |c| !c.named? && c.type == "abstract" }
      header = TypeHeader.new(path, global, params, splat,
        node.field_text(Syntax::Field::Superclass), is_abstract,
        kind.enum? ? node.field_text(Syntax::Field::Type) : nil)
      result = Item.new(kind, path.last, node.range, (name_node || node).range,
        visibility: vis, doc: doc_for(node), conditions: @conds.dup, header: header)
      if body = node.field(Syntax::Field::Body)
        lower_body(body, result.children, result)
      end
      result
    end

    # -- defs, macros, funs --------------------------------------------------

    # `@x = v` / `@@x = v` assignments in a def body, as `Origin::Assigned`
    # ivar items of the owner (type_inference.md: the compiler types
    # undeclared ivars from these syntactic forms). Nested blocks count;
    # nested defs and type bodies don't.
    private def assigned_ivars(def_node : Syntax::Node, sig : Signature, def_name : String) : Array(Item)
      found = [] of Item
      # `def initialize(@x : T, @y = v)`: params that assign ivars (any def).
      def_node.field(Syntax::Field::Params).try &.named_children.each do |p|
        next unless p.kind.param?
        iv = p.field(Syntax::Field::Name) || next
        next unless iv.kind.instance_var? || iv.kind.class_var?
        detail = if r = p.field_text(Syntax::Field::Type)
                   ": #{r}"
                 elsif d = p.field_text(Syntax::Field::Default)
                   "= #{d}"
                 else
                   "?"
                 end
        k = iv.kind.instance_var? ? ItemKind::InstanceVar : ItemKind::ClassVar
        found << Item.new(k, iv.text, p.range, iv.range, origin: Origin::Param, doc: def_name,
          conditions: @conds.dup, detail: detail)
      end
      body = def_node.field(Syntax::Field::Body) || return found
      params = sig.params.to_h { |p| {p.name || "", p} }
      body.walk do |n|
        next false if n.kind.method_def? || n.kind.class_def? || n.kind.struct_def? || n.kind.module_def? ||
                      n.kind.macro_def? || n.kind.macro_content? || n.kind.proc_node?
        if n.kind.assign? && (lhs = n.field(Syntax::Field::Lhs)) && (lhs.kind.instance_var? || lhs.kind.class_var?)
          rhs = n.field(Syntax::Field::Rhs)
          text = rhs.try(&.text) || ""
          # `@x = name`: the param's restriction or default, if any.
          if rhs && rhs.kind.identifier? && (p = params[rhs.text]?)
            text = if r = p.restriction
                     ": #{r}"
                   elsif d = p.default
                     "= #{d}"
                   else
                     "?"
                   end
          end
          k = lhs.kind.instance_var? ? ItemKind::InstanceVar : ItemKind::ClassVar
          found << Item.new(k, lhs.text, n.range, lhs.range, origin: Origin::Assigned, doc: def_name,
            conditions: @conds.dup, detail: text)
        end
        # `LibX.f(out @x)` (rule 7): assigned, but typed by compiler facts
        # only; recorded with an untypeable value.
        if n.kind.out? && (iv = n.named_child(0)) && iv.kind.instance_var?
          found << Item.new(ItemKind::InstanceVar, iv.text, n.range, iv.range, origin: Origin::Assigned, doc: def_name,
            conditions: @conds.dup, detail: "?")
        end
        true
      end
      found
    end

    private def lower_def(node : Syntax::Node, kind : ItemKind, vis : Visibility, *, is_abstract : Bool) : Item
      name_node = node.field(Syntax::Field::Name)
      receiver = node.fields(Syntax::Field::ClassNode).find(&.named?).try(&.text)
      params = [] of Param
      variadic = false
      if list = node.field(Syntax::Field::Params)
        list.children.each do |p|
          variadic = true if !p.named? && p.type == "..."
          next unless p.named?
          params << lower_param(p)
        end
      end
      free_vars = node.field(Syntax::Field::Forall).try(&.named_children.map(&.text)) || [] of String
      sig = Signature.new(params, node.field_text(Syntax::Field::Type), free_vars, receiver,
        is_abstract, variadic, node.field_text(Syntax::Field::RealName))
      Item.new(kind, name_node.try(&.text) || "?", node.range, (name_node || node).range,
        visibility: vis, doc: doc_for(node), conditions: @conds.dup, signature: sig)
    end

    private def lower_param(p : Syntax::Node) : Param
      kind = case p.kind
             when .splat_param?        then ParamKind::Splat
             when .double_splat_param? then ParamKind::DoubleSplat
             when .block_param?        then ParamKind::Block
             else                           ParamKind::Positional
             end
      # `fun puts(UInt8*)` has a bare type as parameter.
      if kind.positional? && !p.kind.param? && !p.kind.fun_param?
        return Param.new(kind, nil, nil, p.text, nil, p.range)
      end
      Param.new(kind, p.field_text(Syntax::Field::Name), p.field_text(Syntax::Field::ExternName),
        p.field_text(Syntax::Field::Type), p.field_text(Syntax::Field::Default), p.range)
    end

    # -- known macro calls ----------------------------------------------------

    private def lower_macro_call(node : Syntax::Node, dest : Array(Item), owner : Item?, vis : Visibility) : Nil
      return if node.field(Syntax::Field::Receiver)
      method = node.field_text(Syntax::Field::Method) || return
      args = node.field(Syntax::Field::Arguments).try(&.named_children) || [] of Syntax::Node

      if spec = ACCESSORS[method]?
        class_level = method.starts_with?("class_")
        args.each do |arg|
          name_node, type, default = accessor_target(arg)
          next unless name_node
          name = name_node.kind.string_node? ? string_value(name_node) : name_node.text.lchop(':')
          receiver = class_level ? "self" : nil
          if spec[:getter]
            # `getter! x : T` defines `x : T` (raises on nil) and `x? : T?`.
            getters = spec[:suffix] == "!" ? [{name, type}, {name + "?", type.try { |t| "#{t}?" }}] : [{name + spec[:suffix], type}]
            getters.each do |(gname, gtype)|
              sig = Signature.new([] of Param, gtype, [] of String, receiver, false, false, nil)
              dest << Item.new(ItemKind::Def, gname, node.range, name_node.range,
                visibility: vis, origin: Origin::Macro, doc: doc_for(node), conditions: @conds.dup, signature: sig)
            end
          end
          if spec[:setter]
            param = Param.new(ParamKind::Positional, name, nil, type, nil, name_node.range)
            sig = Signature.new([param], nil, [] of String, receiver, false, false, nil)
            dest << Item.new(ItemKind::Def, name + "=", node.range, name_node.range,
              visibility: vis, origin: Origin::Macro, doc: doc_for(node), conditions: @conds.dup, signature: sig)
          end
          if owner
            ivar = (class_level ? "@@" : "@") + name
            dest << Item.new(class_level ? ItemKind::ClassVar : ItemKind::InstanceVar, ivar, node.range, name_node.range,
              visibility: vis, origin: Origin::Macro, conditions: @conds.dup, detail: type || default)
          end
        end
      elsif method == "record" && (name_node = args.first?) && name_node.kind.constant?
        lower_record(node, name_node, args[1..], dest, vis)
      end
    end

    # `getter x`, `getter x : T`, `getter x = v`, `getter x : T = v`, `getter :x`.
    private def accessor_target(arg : Syntax::Node) : {Syntax::Node?, String?, String?}
      case arg.kind
      when .identifier?, .symbol_node?, .string_node?
        {arg, nil, nil}
      when .type_declaration?
        {arg.field(Syntax::Field::Var), arg.field_text(Syntax::Field::Type), arg.field_text(Syntax::Field::Value)}
      when .assign?
        {arg.field(Syntax::Field::Lhs), nil, arg.field_text(Syntax::Field::Rhs)}
      else
        {nil, nil, nil}
      end
    end

    private def lower_record(node : Syntax::Node, name_node : Syntax::Node, fields : Array(Syntax::Node), dest : Array(Item), vis : Visibility) : Nil
      header = TypeHeader.new([name_node.text], false, [] of String, nil, nil, false, nil)
      rec = Item.new(ItemKind::Struct, name_node.text, node.range, name_node.range,
        visibility: vis, origin: Origin::Macro, doc: doc_for(node), conditions: @conds.dup, header: header)
      params = [] of Param
      fields.each do |f|
        name_node2, type, default = accessor_target(f)
        next unless name_node2
        name = name_node2.text
        params << Param.new(ParamKind::Positional, name, nil, type, default, f.range)
        sig = Signature.new([] of Param, type, [] of String, nil, false, false, nil)
        rec.children << Item.new(ItemKind::Def, name, f.range, name_node2.range, origin: Origin::Macro, signature: sig)
        rec.children << Item.new(ItemKind::InstanceVar, "@#{name}", f.range, name_node2.range, origin: Origin::Macro, detail: type || default)
      end
      init = Signature.new(params, nil, [] of String, nil, false, false, nil)
      rec.children.unshift Item.new(ItemKind::Def, "initialize", node.range, name_node.range, origin: Origin::Macro, signature: init)
      dest << rec
    end

    # -- macro conditionals ----------------------------------------------------

    private def lower_macro_if(node : Syntax::Node, dest : Array(Item), owner : Item?, vis : Visibility) : Nil
      cond = node.field(Syntax::Field::Cond).try { |c| parse_cond(c) } || Cond::Unknown.new("?")
      cond = Cond::Not.new(cond) if node.kind.macro_unless?
      with_cond(cond) do
        node.field(Syntax::Field::Then).try { |b| lower_macro_body(b, dest, owner, vis) }
      end
      if alt = node.field(Syntax::Field::Else)
        with_cond(Cond::Not.new(cond)) do
          if alt.kind.macro_elsif?
            lower_macro_if(alt, dest, owner, vis)
          else
            alt.field(Syntax::Field::Body).try { |b| lower_macro_body(b, dest, owner, vis) }
          end
        end
      end
    end

    # A macro block body: reparse its `macro_content` pieces as Crystal code;
    # nested `{% if %}` are lowered recursively. Other macro expressions
    # (`{{ }}`, `{% for %}`) are skipped: their output is unknown.
    private def lower_macro_body(body : Syntax::Node, dest : Array(Item), owner : Item?, vis : Visibility) : Nil
      ranges = [] of TextRange
      flush = -> do
        unless ranges.empty?
          sub = parser.parse_ranges(@tree.text, ranges, @tree.line_index)
          lower_body(sub.root, dest, owner)
          ranges = [] of TextRange
        end
      end
      body.named_children.each do |child|
        if child.kind.macro_content?
          ranges << child.range
        elsif child.kind.macro_if? || child.kind.macro_unless?
          flush.call
          lower_macro_if(child, dest, owner, vis)
        end
      end
      flush.call
    end

    private def with_cond(cond : Cond, &) : Nil
      @conds.push(cond)
      yield
    ensure
      @conds.pop
    end

    private def parse_cond(node : Syntax::Node) : Cond
      case node.kind
      when .and?
        l, r = node.named_children.reject(&.kind.operator?)
        Cond::And.new(parse_cond(l), parse_cond(r))
      when .or?
        l, r = node.named_children.reject(&.kind.operator?)
        Cond::Or.new(parse_cond(l), parse_cond(r))
      when .not?
        inner = node.named_children.reject(&.kind.operator?).first?
        inner ? Cond::Not.new(parse_cond(inner)) : Cond::Unknown.new(node.text)
      when .expressions?
        node.named_child_count == 1 ? parse_cond(node.named_child(0).not_nil!) : Cond::Unknown.new(node.text)
      when .call?
        if node.field_text(Syntax::Field::Method) == "flag?" && node.field(Syntax::Field::Receiver).nil? &&
           (arg = node.field(Syntax::Field::Arguments).try(&.named_child(0)))
          Cond::Flag.new(arg.text.lchop(':').strip('"'))
        else
          Cond::Unknown.new(node.text)
        end
      else
        Cond::Unknown.new(node.text)
      end
    end

    # -- error recovery ---------------------------------------------------------

    # Inside an ERROR node, look for `keyword constant` sequences that began
    # a namespace whose `*_def` node was lost, and lower everything after
    # them as that namespace's body.
    private def lower_error(node : Syntax::Node, dest : Array(Item), owner : Item?, vis : Visibility) : Nil
      children = node.children
      i = 0
      while i < children.size
        child = children[i]
        if !child.named? && (kind = ERROR_KEYWORDS[child.type]?) &&
           (name = children[i + 1]?) && (name.kind.constant? || name.kind.generic_type?)
          path = name.text.lchop("::").split("::")
          header = TypeHeader.new(path, name.text.starts_with?("::"), [] of String, nil, nil, false, nil)
          ns = Item.new(kind, path.last, TextRange.new(child.start_byte, node.end_byte), name.range,
            visibility: vis, doc: doc_for(child), conditions: @conds.dup, header: header)
          rest = children[(i + 2)..]
          rest.each { |c| lower_stmt(c, ns.children, ns, Visibility::Public) if c.named? }
          dest << ns
          return
        end
        lower_stmt(child, dest, owner, vis) if child.named?
        i += 1
      end
    end

    # -- helpers -------------------------------------------------------------

    private def item(kind, name, node, name_node, vis, *, detail = nil) : Item
      Item.new(kind, name, node.range, name_node.range, visibility: vis,
        doc: doc_for(node), conditions: @conds.dup, detail: detail)
    end

    # Doc comment: consecutive `#` lines directly above the declaration (or
    # above its annotations / visibility modifier), with no blank line.
    #
    # Read from source text rather than siblings: the grammar sometimes puts
    # a body's first comment outside the body node.
    private def doc_for(node : Syntax::Node) : String?
      anchor = node
      while (parent = anchor.parent) && parent.kind.visibility_modifier?
        anchor = parent
      end
      index = @tree.line_index
      line = index.line_of(anchor.start_byte).to_i
      lines = [] of String
      while line > 0
        line -= 1
        text = line_text(index, line.to_u32).strip
        if text.starts_with?('#')
          lines.unshift(text.lchop('#').lchop(' '))
        elsif text.starts_with?("@[") && text.ends_with?(']')
          next
        else
          break
        end
      end
      lines.empty? ? nil : lines.join('\n')
    end

    private def line_text(index : LineIndex, line : UInt32) : String
      r = index.line_range(line)
      @tree.text.byte_slice(r.start, r.size)
    end

    private def annotation_text(node : Syntax::Node) : String
      node.text.lchop("@[").rchop("]")
    end

    private def string_value(node : Syntax::Node) : String
      node.named_children.select(&.kind.literal_content?).join(&.text)
    end

    private def parser : Syntax::Parser
      @parser ||= Syntax::Parser.new
    end
  end
end
