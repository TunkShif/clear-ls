require "../workspace/index"
require "./locals"
require "./typing"
require "./type_params"
require "./annotations"
require "./annotation_args"
require "./pseudo_docs"

module ClearLS::IDE
  # A location in a file, as byte ranges. The LSP layer converts to
  # protocol positions.
  record Location, file : FileId, range : TextRange

  record SymbolInfo,
    name : String,
    detail : String?,
    kind : Items::ItemKind,
    range : TextRange,
    selection_range : TextRange,
    children : Array(SymbolInfo)

  record WorkspaceSymbolInfo, name : String, container : String?, kind : Items::ItemKind, location : Location

  record HoverInfo, markdown : String, range : TextRange

  record FoldInfo, start_line : UInt32, end_line : UInt32, comment : Bool

  record LinkInfo, range : TextRange, target : String

  # Protocol-independent editor features over one file plus the index.
  #
  # Phase 1 features use only declarations: no body analysis.
  class Analysis
    def initialize(@state : FileState, @index : Workspace::Index, @def_map : Semantics::DefMap = index.def_map)
    end

    # Type parameter or `forall` variable at *offset* (TypeParams).
    def type_param_at(offset : UInt32) : TypeParams::Hit?
      TypeParams.at(@state, offset, def_map, ->(f : FileId) { file_text(f) })
    end

    private def file_text(file : FileId) : String?
      path = @index.entry?(file).try(&.path) || return nil
      File.read(path)
    rescue File::Error
      nil
    end

    private def tree : Syntax::Tree
      @state.tree
    end

    private def def_map : Semantics::DefMap
      @def_map
    end

    # -- document symbols ----------------------------------------------------

    def document_symbols : Array(SymbolInfo)
      items = Items::Lower.lower(tree)
      items.items.compact_map { |i| symbol(i) }
    end

    private def symbol(item : Items::Item) : SymbolInfo?
      return nil if item.kind.instance_var? && item.origin.macro?
      # `initialize(@x)`: shown as the def's param.
      return nil if item.origin.param?
      children = item.children.compact_map { |c| symbol(c).as(SymbolInfo?) }
      SymbolInfo.new(display_name(item), detail(item), item.kind, item.range, item.name_range, children)
    end

    private def display_name(item : Items::Item) : String
      if (s = item.signature) && (r = s.receiver)
        "#{r}.#{item.name}"
      elsif h = item.header
        h.path.join("::")
      else
        item.name
      end
    end

    private def detail(item : Items::Item) : String?
      if s = item.signature
        s.to_s
      elsif h = item.header
        h.superclass.try { |sc| "< #{sc}" }
      else
        item.detail
      end
    end

    # -- workspace symbols ---------------------------------------------------

    MAX_WORKSPACE_SYMBOLS = 512

    # Fuzzy subsequence match, case-insensitive, over every index (a file
    # in several indexes counts once); files under one of *roots*
    # (default: the indexes' roots) first.
    def self.workspace_symbols(indexes : Array(Workspace::Index), query : String, roots : Array(String) = indexes.map(&.project.root)) : Array(WorkspaceSymbolInfo)
      q = query.downcase
      own = [] of WorkspaceSymbolInfo
      other = [] of WorkspaceSymbolInfo
      prefixes = roots.map { |r| r.ends_with?('/') ? r : r + "/" }
      seen = Set(FileId).new
      indexes.each do |index|
        index.each_entry do |file, entry|
          next unless seen.add?(file)
          bucket = prefixes.any? { |r| entry.path.starts_with?(r) } ? own : other
          each_named(entry.items.items, nil) do |item, container|
            next if item.kind.instance_var? || item.kind.class_var? || item.kind.c_field?
            next unless subsequence?(q, item.name.downcase)
            bucket << WorkspaceSymbolInfo.new(item.name, container, item.kind, Location.new(file, item.name_range))
          end
        end
      end
      rank = ->(s : WorkspaceSymbolInfo) { {s.name.downcase == q ? 0 : s.name.downcase.starts_with?(q) ? 1 : 2, s.name.size} }
      (own.sort_by!(&rank) + other.sort_by!(&rank)).first(MAX_WORKSPACE_SYMBOLS)
    end

    # Yields each item with its full container name. For `class A::B` the
    # path prefix `A` is part of the container.
    private def self.each_named(items : Array(Items::Item), container : String?, &block : Items::Item, String? ->) : Nil
      items.each do |item|
        path = item.header.try(&.path) || [item.name]
        prefix = path[0...-1].join("::").presence
        own = [container, prefix].compact.join("::").presence
        block.call(item, own)
        if item.kind.namespace?
          each_named(item.children, [own, item.name].compact.join("::"), &block)
        end
      end
    end

    private def self.subsequence?(query : String, name : String) : Bool
      i = 0
      name.each_char do |c|
        break if i == query.size
        i += 1 if c == query[i]
      end
      i == query.size
    end

    # -- folding / selection ---------------------------------------------------

    FOLD_KINDS = [
      Syntax::Kind::ModuleDef, Syntax::Kind::ClassDef, Syntax::Kind::StructDef,
      Syntax::Kind::EnumDef, Syntax::Kind::LibDef, Syntax::Kind::MethodDef,
      Syntax::Kind::MacroDef, Syntax::Kind::Block, Syntax::Kind::If, Syntax::Kind::Unless,
      Syntax::Kind::Case, Syntax::Kind::While, Syntax::Kind::Until, Syntax::Kind::Begin,
      Syntax::Kind::ArrayNode, Syntax::Kind::HashNode, Syntax::Kind::MacroIf,
      Syntax::Kind::MacroFor, Syntax::Kind::HeredocBody, Syntax::Kind::AnnotationDef,
      Syntax::Kind::CStructDef, Syntax::Kind::UnionDef,
    ].to_set

    def folding_ranges : Array(FoldInfo)
      result = [] of FoldInfo
      comment_start = nil.as(UInt32?)
      comment_end = 0_u32
      flush = -> do
        if (s = comment_start) && comment_end > s
          result << FoldInfo.new(s, comment_end, true)
        end
        comment_start = nil
      end
      tree.root.walk do |node|
        if node.kind.comment?
          first, last = node.lines
          if comment_start && first == comment_end + 1
            comment_end = last
          else
            flush.call
            comment_start, comment_end = first, last
          end
          next false
        end
        if FOLD_KINDS.includes?(node.kind)
          first, last = node.lines
          # Keep the closing `end` visible.
          last -= 1 if node.text.ends_with?("end") && last > first
          result << FoldInfo.new(first, last, false) if last > first
        end
        true
      end
      flush.call
      result
    end

    # Nested ranges from the smallest named node at *offset* outwards.
    def selection_ranges(offset : UInt32) : Array(TextRange)
      node = tree.root.descendant(offset, offset) || return [] of TextRange
      ranges = [] of TextRange
      cur = node.as(Syntax::Node?)
      while c = cur
        r = c.range
        ranges << r if ranges.empty? || ranges.last != r
        cur = c.parent
      end
      ranges
    end

    # -- definition / hover ------------------------------------------------------

    # Type and constant targets at *offset*. Require targets are files and
    # come from `#require_definitions`.
    def definition(offset : UInt32) : Array(Location)
      if tp = type_param_at(offset)
        return [Location.new(tp.decl_file, tp.decl)]
      end
      resolve_path_at(offset).flat_map { |r| r[:sites] }.map { |s| Location.new(s.file, s.item.name_range) }
    end

    def hover(offset : UInt32) : HoverInfo?
      if node = require_node(offset)
        path = require_path(node) || return nil
        targets = resolve_require(path)
        return nil if targets.empty?
        return HoverInfo.new("```\n#{targets[0]}\n```", node.range) unless glob?(path)
        return HoverInfo.new(glob_hover(targets), node.range)
      end
      if tp = type_param_at(offset)
        role = tp.role.free_var? ? "free variable of `#{tp.owner}` (`forall #{tp.name}`)" : "type parameter of `#{tp.owner}`"
        return HoverInfo.new("```crystal\n#{tp.name}\n```\n\n#{role}", tp.range)
      end
      results = resolve_path_at(offset)
      if hit = pseudo_hover(offset, results.empty?)
        return hit
      end
      if hit = annotation_arg_hover(offset)
        return hit
      end
      if hit = builtin_annotation_hover(offset, results.first?)
        return hit
      end
      first = results.first? || return nil
      md = String.build do |io|
        first[:sites].first(1).each { |s| describe(s.item, first[:full_name], io) }
        if first[:sites].size > 1
          io << "\n\n_" << first[:sites].size << " declarations_"
        end
      end
      HoverInfo.new(md, first[:range])
    end

    # The `constant` naming the annotation in `@[Name(...)]` at *offset*.
    def annotation_name_at(offset : UInt32) : Syntax::Node?
      node = tree.root.descendant(offset, offset, named: true) || return nil
      node = node.parent.not_nil! if !node.kind.constant? && node.parent.try(&.kind.constant?)
      return nil unless node.kind.constant?
      parent = node.parent || return nil
      parent.kind.annotation_node? && parent.named_child(0) == node ? node : nil
    end

    # Keyword pseudo-methods whose node starts with the keyword.
    PSEUDO_KEYWORDS = %w(typeof sizeof instance_sizeof alignof instance_alignof pointerof offsetof)

    # On a compiler pseudo-method keyword (`sizeof(...)`) or on `Void` /
    # `NoReturn` used as a type: docs from `docs_pseudo_methods.cr`.
    # *unresolved*: the constant under the cursor resolved to no type (a
    # user's `Void` wins).
    private def pseudo_hover(offset : UInt32, unresolved : Bool) : HoverInfo?
      std = @index.project.stdlib_dir
      leaf = tree.root.descendant(offset, offset) || return nil
      if !leaf.named? && (parent = leaf.parent) && PSEUDO_KEYWORDS.includes?(leaf.type) && parent.type == leaf.type
        e = PseudoDocs.lookup(std, leaf.type) || return nil
        return HoverInfo.new(PseudoDocs.markdown(e), leaf.range)
      end
      return nil unless unresolved
      node = tree.root.descendant(offset, offset, named: true) || return nil
      return nil unless node.kind.constant? && node.text.lchop("::").in?("Void", "NoReturn")
      e = PseudoDocs.lookup(std, node.text.lchop("::")) || return nil
      HoverInfo.new(PseudoDocs.markdown(e), node.range)
    end

    # On an annotation argument: `ldflags` in `@[Link(ldflags: "x")]`
    # (the name), or a positional value the compiler names
    # (`"m"` → `lib`): the argument's type and doc.
    private def annotation_arg_hover(offset : UInt32) : HoverInfo?
      node = tree.root.descendant(offset, offset, named: true) || return nil
      arg = node
      while (p = arg.parent) && !p.kind.argument_list?
        arg = p
      end
      list = arg.parent || return nil
      ann = list.parent || return nil
      return nil unless ann.kind.annotation_node? && list == ann.field(Syntax::Field::Arguments)
      name_node = ann.named_child(0) || return nil
      map = def_map
      ns = map.namespace_at(@state.id, ann.start_byte)
      std = ->(f : FileId) { @index.stdlib_file?(f) }
      full, args = AnnotationArgs.for_path(map, ns, name_node.text, std) || return nil
      if arg.kind.named_expr?
        key = arg.field(Syntax::Field::Name) || return nil
        return nil unless key.range.touches?(offset)
        a = args.find { |x| x.name == key.text && x.named } || return nil
        range = key.range
      else
        pos = list.named_children.take_while { |c| c != arg }.count { |c| !c.kind.named_expr? && !c.kind.comment? }
        a = args.find { |x| x.position == pos } || return nil
        range = arg.range
      end
      md = String.build do |io|
        io << "```crystal\n" << a.name
        io << " : " << a.type unless a.type.empty?
        io << "\n```\n\nargument of `" << full << '`'
        io << " (positional #" << a.position.not_nil! + 1 << ')' if a.position && !arg.kind.named_expr?
        io << "\n\n" << a.doc unless a.doc.empty?
      end
      HoverInfo.new(md, range)
    end

    # A compiler annotation (`Annotations::BUILTINS`) under the cursor:
    # the table's doc and arguments, with the stdlib declaration's doc
    # when there is one. Nil when the name resolves to something else
    # (a user `annotation Raises` in scope wins, as in the compiler).
    private def builtin_annotation_hover(offset : UInt32, first) : HoverInfo?
      node = annotation_name_at(offset) || return nil
      b = IDE::Annotations.builtin?(node.text) || return nil
      start = node.start_byte + (node.text.starts_with?("::") ? 2 : 0)
      range = TextRange.new(start.to_u32, node.end_byte)
      return nil if offset < start
      unless first
        return HoverInfo.new(IDE::Annotations.markdown(b), range)
      end
      return nil unless first[:full_name] == b.name
      site = first[:sites].find(&.item.kind.annotation?) || return nil
      HoverInfo.new(IDE::Annotations.markdown(b, site.item.doc), first[:range])
    end

    private def describe(item : Items::Item, full_name : String, io : IO) : Nil
      io << "```crystal\n"
      io << item.visibility.to_s.downcase << ' ' unless item.visibility.public?
      case item.kind
      when .namespace?
        h = item.header.not_nil!
        io << "abstract " if h.is_abstract
        keyword = {Items::ItemKind::CStruct => "struct", Items::ItemKind::CUnion => "union"}[item.kind]? || item.kind.to_s.downcase
        io << keyword << ' ' << full_name
        io << '(' << h.type_params.join(", ") << ')' unless h.type_params.empty?
        io << " < " << h.superclass if h.superclass
        io << " : " << h.base_type if h.base_type
      when .alias?     then io << "alias " << full_name << " = " << item.detail
      when .type_def?  then io << "type " << full_name << " = " << item.detail
      when .constant?  then io << full_name << (item.detail ? " = #{item.detail}" : "")
      else                  io << full_name
      end
      io << "\n```"
      if doc = item.doc
        io << "\n\n" << doc
      end
    end

    # Resolves the `constant` node at *offset* up to the segment under the
    # cursor (`Foo::B|ar::Baz` → `Foo::Bar`). Returns resolved types or
    # constants.
    def resolve_path_at(offset : UInt32) : Array(NamedTuple(full_name: String, sites: Array(Semantics::Site), range: TextRange))
      empty = [] of NamedTuple(full_name: String, sites: Array(Semantics::Site), range: TextRange)
      node = tree.root.descendant(offset, offset, named: true) || return empty
      node = node.parent.not_nil! if !node.kind.constant? && node.parent.try(&.kind.constant?)
      return empty unless node.kind.constant?
      # A type parameter shadows a constant of the same name: not a path.
      return empty if !node.text.includes?("::") && type_param_at(node.start_byte)

      text = node.text
      rel = (offset - node.start_byte).to_i.clamp(0, text.bytesize)
      seg_end = text.byte_index("::", rel) || text.bytesize
      # Cursor on a `::` separator selects the segment before it.
      if rel > 0 && text.byte_slice(rel - 1, 2) == "::"
        seg_end = rel - 1
      elsif text.byte_slice(rel, 2) == "::"
        seg_end = rel
      end
      prefix = text.byte_slice(0, seg_end)
      seg_start = (prefix.rindex("::").try(&.+(2))) || 0
      range = TextRange.new(node.start_byte + seg_start, node.start_byte + seg_end)

      map = def_map
      ns = map.namespace_at(@state.id, node.start_byte)
      # Inside a type's own header (`class Foo < Bar`), lookups start in the
      # enclosing namespace, like the compiler.
      if (decl = node.parent) && (decl.kind.class_def? || decl.kind.struct_def? || decl.kind.module_def?)
        ns = map[ns].namespace || Semantics::DefMap::PROGRAM
      end
      # `@[Primitive]`, `@[Flags]`: the compiler takes the top-level
      # annotation whatever is in scope (`File::Flags` is an enum).
      if (decl = node.parent) && decl.kind.annotation_node? && IDE::Annotations::TOP_LEVEL.includes?(text)
        ns = Semantics::DefMap::PROGRAM
      end

      # Aliases are not followed: definition and hover of `Env` go to
      # `alias Env = ...`, and its references are the alias's (the target
      # is one more definition away).
      if id = map.lookup_path_raw(prefix, ns)
        info = map[id]
        sites = info.sites.empty? ? map[map.resolve_alias(id)].sites : info.sites
        return [{full_name: info.full_name, sites: sites, range: range}]
      end
      # Constant member: `Foo::BAR` or plain `BAR` in scope.
      owner_path, _, name = prefix.rpartition("::")
      owners = if owner_path.empty? && !prefix.starts_with?("::")
                 scope_chain(ns)
               else
                 [map.lookup_path(owner_path.empty? ? "::" : owner_path, ns) || Semantics::DefMap::PROGRAM].compact
               end
      owners.each do |owner|
        sites = map.lookup_member(owner, name).select(&.item.kind.constant?)
        unless sites.empty?
          # Through an ancestor (`include Outer`): name it by its declarer.
          declarer = map.ancestors(owner).find { |a| map[a].members[name]?.try { |ms| ms.includes?(sites.first) } } || owner
          full = map[declarer].full_name
          return [{full_name: full.empty? ? name : "#{full}::#{name}", sites: sites, range: range}]
        end
      end
      empty
    end

    # The namespace and its enclosing namespaces, innermost first.
    private def scope_chain(ns : Semantics::TypeId) : Array(Semantics::TypeId)
      chain = [] of Semantics::TypeId
      cur = ns.as(Semantics::TypeId?)
      while c = cur
        chain << c
        cur = def_map[c].namespace
      end
      chain
    end

    # -- require links -----------------------------------------------------------

    def document_links : Array(LinkInfo)
      links = [] of LinkInfo
      tree.root.walk do |node|
        if node.kind.require?
          if (path = require_path(node)) && (str = node.named_child(0)) && (target = resolve_require(path).first?)
            # A glob has many targets; link to the directory it lists.
            target = File.dirname(target) if glob?(path)
            links << LinkInfo.new(str.range, target)
          end
          false
        else
          !(node.kind.method_def? || node.kind.comment?)
        end
      end
      links
    end

    private def require_node(offset : UInt32) : Syntax::Node?
      node = tree.root.descendant(offset, offset, named: true)
      while n = node
        return n if n.kind.require?
        node = n.parent
      end
      nil
    end

    private def require_path(node : Syntax::Node) : String?
      str = node.named_child(0) || return nil
      str.named_children.select(&.kind.literal_content?).join(&.text).presence
    end

    def resolve_require(path : String) : Array(String)
      from = VFS.path_for(@state.uri)
      @index.project.resolver.resolve(path, from)
    end

    # Absolute paths targeted by a `require` at *offset* (every file of a
    # `dir/*` / `dir/**` glob); empty when none.
    def require_definitions(offset : UInt32) : Array(String)
      node = require_node(offset) || return [] of String
      path = require_path(node) || return [] of String
      resolve_require(path)
    end

    MAX_GLOB_HOVER = 20

    private def glob?(path : String) : Bool
      path.ends_with?("/*") || path.ends_with?("/**")
    end

    # Files of a glob require, relative to the requiring file's directory.
    private def glob_hover(targets : Array(String)) : String
      base = VFS.path_for(@state.uri).try { |p| File.dirname(p) }
      String.build do |io|
        io << "```\n"
        targets.first(MAX_GLOB_HOVER).each do |t|
          io << (base ? Path[t].relative_to(base).to_s : t) << '\n'
        end
        io << "```"
        io << "\n\n" << targets.size << " files" if targets.size > 1
        io << " (" << targets.size - MAX_GLOB_HOVER << " more not shown)" if targets.size > MAX_GLOB_HOVER
      end
    end
  end
end
