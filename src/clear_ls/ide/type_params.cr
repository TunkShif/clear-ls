require "../vfs"
require "../semantics/def_map"

module ClearLS::IDE
  # Type parameters (`T` of `class Box(T)`) and free variables (`U` of
  # `def map(...) forall U`) under the cursor, resolved like the compiler
  # (checked with Crystal 1.22):
  #
  # - a def's `forall` names come first (they shadow a type param);
  # - then the params of the innermost enclosing type declaration, or of
  #   another declaration of the same type that has them (`class Box`
  #   reopening `class Box(T)`);
  # - a nested type doesn't see its outer type's params (`Outer(T)::Inner`);
  # - a param shadows a constant of the same name (`class Store(Key)`).
  #
  # Only single-segment constants are candidates (`T`, not `Foo::T`).
  module TypeParams
    enum Role
      TypeParam
      FreeVar
    end

    # *decl*: the declaring token; *owner*: `Box(T)` or the def's name.
    record Hit, name : String, role : Role, decl_file : FileId, decl : TextRange, owner : String, range : TextRange

    # *text_of*: text of another file (a reopening's header elsewhere).
    alias TextOf = Proc(FileId, String?)

    def self.at(state : FileState, offset : UInt32, map : Semantics::DefMap, text_of : TextOf) : Hit?
      node = state.tree.root.descendant(offset, offset, named: true) || return nil
      return nil unless node.kind.constant?
      name = node.text
      return nil if name.includes?("::")
      resolve(state, node, name, map, text_of)
    end

    # The parameter *name* at constant *node* means, or nil.
    def self.resolve(state : FileState, node : Syntax::Node, name : String, map : Semantics::DefMap, text_of : TextOf) : Hit?
      cur = node.parent
      while n = cur
        if n.kind.method_def? || n.kind.abstract_method_def?
          if (f = n.field(Syntax::Field::Forall)) && (d = f.named_children.find { |c| c.text == name })
            def_name = n.field_text(Syntax::Field::Name) || "def"
            return Hit.new(name, Role::FreeVar, state.id, d.range, def_name, node.range)
          end
        elsif type_decl?(n)
          # The innermost type decides: params of an outer type are not
          # visible in a nested one.
          return type_param(state, n, node, name, map, text_of)
        end
        cur = n.parent
      end
      nil
    end

    # Every use of *hit*'s parameter in this file (constants that resolve
    # to the same declaration), including the declaring token here.
    def self.uses(state : FileState, hit : Hit, map : Semantics::DefMap) : Array(TextRange)
      found = [] of TextRange
      found << hit.decl if hit.decl_file == state.id
      state.tree.root.walk do |n|
        if n.kind.constant? && n.text == hit.name && n.range != hit.decl
          r = resolve(state, n, hit.name, map, ->(_f : FileId) { nil.as(String?) })
          found << n.range if r && r.decl_file == hit.decl_file && (r.decl == hit.decl || hit.decl_file != state.id)
        end
        true
      end
      found.uniq.sort_by(&.start)
    end

    private def self.type_decl?(n : Syntax::Node) : Bool
      n.kind.class_def? || n.kind.struct_def? || n.kind.module_def?
    end

    # *name* among the params of type declaration *decl*, or of another
    # declaration (reopening) of the same type.
    private def self.type_param(state : FileState, decl : Syntax::Node, node : Syntax::Node, name : String, map : Semantics::DefMap, text_of : TextOf) : Hit?
      header = decl.field(Syntax::Field::Name) || return nil
      # The header's own name (`Box` in `class Box(T)`) is not a param.
      return nil if node.start_byte < header.end_byte && !in_params?(header, node)
      if (d = param_token(header, name))
        return Hit.new(name, Role::TypeParam, state.id, d.range, owner_text(header), node.range)
      end
      # A reopening without params: the type's params, declared elsewhere.
      ns = map.namespace_at(state.id, decl.start_byte + 1)
      info = map[ns]
      return nil unless info.type_params.includes?(name)
      site = info.sites.find { |s| s.item.header.try(&.type_params.includes?(name)) } || return nil
      tp = site.item.header.not_nil!
      text = site.file == state.id ? state.text : text_of.call(site.file)
      Hit.new(name, Role::TypeParam, site.file, text.try { |t| param_range(t, site, name) } || site.item.name_range,
        "#{info.full_name}(#{tp.type_params.join(", ")})", node.range)
    end

    private def self.in_params?(header : Syntax::Node, node : Syntax::Node) : Bool
      params = header.field(Syntax::Field::Params) || return false
      params.range.touches?(node.start_byte)
    end

    # `T` in `Box(T)` / `Pair(K, *V)`.
    private def self.param_token(header : Syntax::Node, name : String) : Syntax::Node?
      return nil unless header.kind.generic_type?
      params = header.field(Syntax::Field::Params) || return nil
      params.named_children.each do |p|
        t = p.kind.splat? ? p.named_child(0) : p
        return t if t && t.text == name
      end
      nil
    end

    private def self.owner_text(header : Syntax::Node) : String
      header.text.gsub(/\s+/, " ")
    end

    # The param's token in another declaration's header: the name range
    # covers `Box(K, *V)`.
    private def self.param_range(text : String, site : Semantics::Site, name : String) : TextRange?
      r = site.item.name_range
      return nil if r.end > text.bytesize
      header = text.byte_slice(r.start, r.size)
      open = header.byte_index('(') || return nil
      inner = header.byte_slice(open + 1, header.bytesize - open - 1)
      m = inner.match(/(?<![\w])#{Regex.escape(name)}(?![\w])/) || return nil
      s = r.start + open + 1 + m.byte_begin(0)
      TextRange.new(s.to_u32, (s + name.bytesize).to_u32)
    end
  end
end
