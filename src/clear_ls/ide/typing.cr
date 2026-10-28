require "../types"
require "./locals"

module ClearLS::IDE
  # Type inference results for the bodies of one file revision, plus a
  # loader that parses other files' defs on demand (for yield summaries).
  #
  # One `Typing` per (DefMap generation): the TypeTable and caches are
  # rebuilt when declarations change.
  class Typing
    getter table : Types::TypeTable
    getter def_map : Semantics::DefMap

    # Parsed def ranges / file texts we looked into (bounded, FIFO).
    MAX_TREES = 256
    @trees = {} of {FileId, UInt32} => Syntax::Tree
    @parser = Syntax::Parser.new
    @results = {} of {FileId, UInt64, UInt32} => Types::Infer

    getter summaries : Types::Summaries

    def initialize(@def_map : Semantics::DefMap, @vfs : VFS)
      @table = Types::TypeTable.new(@def_map)
      @summaries = Types::Summaries.new(@table)
      vfs = @vfs
      @summaries.revision_of = ->(id : FileId) { vfs.file?(vfs.uri(id)).try(&.revision) || 0_u64 }
      # Ivar rule 4: a class method whose last expression is `new(...)`.
      Types::Infer.news_check = ->(site : Semantics::Site) { ends_in_new?(site) }
    end

    # What a references search needs from one call: where its name is,
    # how it resolved, and the targets (`{file, name start}` of each
    # matched def). `resolved` is false when inference never evaluated
    # the call.
    record CallFact, name_range : TextRange, resolved : Bool, kind : Types::ResolutionKind,
      targets : Array({Int32, UInt32}), has_receiver : Bool,
      named_args : Array({String, TextRange}) = [] of {String, TextRange},
      init_targets : Array({Int32, UInt32}) = [] of {Int32, UInt32}

    alias BodyCalls = Hash(String, Array(CallFact))

    # Call facts per file (latest revision only) and body start. A few
    # bytes per call (Marten's 89k calls: ~13 MB), against ~100 KB per
    # body for a kept `Infer`: the background warm-up fills these, not
    # `@results`.
    @call_facts = {} of FileId => {UInt64, Hash(UInt32, BodyCalls)}

    # Calls of the body containing *offset*, by name; computed once per
    # file revision (from a cached `Infer` when there is one).
    def call_facts(state : FileState, bodies : Bodies, offset : UInt32) : {HIR::Body, BodyCalls}?
      body = bodies.at(offset) || return nil
      rev, per_body = @call_facts[state.id]?.try { |e| e[0] == state.revision ? e : nil } ||
                      (@call_facts[state.id] = {state.revision, {} of UInt32 => BodyCalls})
      if calls = per_body[body.range.start]?
        return {body, calls}
      end
      inf = @results[{state.id, state.revision, body.range.start}]? || run(state, body)
      calls = BodyCalls.new
      body.exprs.each do |e|
        next unless e.kind.call?
        name = e.name || next
        nr = e.name_range || next
        res = inf.resolutions[e.id]?
        targets = res ? res.matches.map { |m| {m.site.file.value.to_i32, m.site.item.name_range.start} } : [] of {Int32, UInt32}
        # `Foo.new(...)` reaching `initialize`: its named arguments name
        # initialize's params (record fields).
        inits = inf.initialize_resolution(e).try &.matches.map { |m| {m.site.file.value.to_i32, m.site.item.name_range.start} }
        kind = res.try(&.kind) || Types::ResolutionKind::Unresolved
        named = e.named_args.compact_map { |(n, v)| named_key_range(state, body.expr(v), n) }
        (calls[name] ||= [] of CallFact) << CallFact.new(nr, !res.nil?, kind, targets, !e.receiver.nil?, named, inits || [] of {Int32, UInt32})
      end
      per_body[body.range.start] = calls
      {body, calls}
    end

    # The `k` of `k: v` written before the value *v* (named argument).
    private def named_key_range(state : FileState, v : HIR::Expr, name : String) : {String, TextRange}?
      text = state.text
      i = v.range.start.to_i
      while i > 0 && text.byte_at(i - 1).unsafe_chr.whitespace?
        i -= 1
      end
      return nil unless i > 0 && text.byte_at(i - 1) == ':'.ord
      stop = i - 1
      start = stop - name.bytesize
      return nil unless start >= 0 && text.byte_slice(start, name.bytesize) == name
      {name, TextRange.new(start.to_u32, stop.to_u32)}
    end

    # Inference for the body containing *offset* in *state*.
    #
    # *cache*: false for throwaway patched copies (completion, signature
    # help). They share the real file's id and a derived revision, so two
    # different patches of one revision would hit each other's results.
    def infer_at(state : FileState, bodies : Bodies, offset : UInt32, cache = true) : {HIR::Body, Types::Infer}?
      body = bodies.at(offset) || return nil
      return {body, run(state, body)} unless cache
      key = {state.id, state.revision, body.range.start}
      inf = @results[key] ||= run(state, body)
      {body, inf}
    end

    private def run(state : FileState, body : HIR::Body) : Types::Infer
      # A file body spans every namespace of the file; its own namespace
      # is the program (code inside `class Foo ... end` gets Foo through
      # `type_body_ns`). `namespace_at(0)` would pick a type declared at
      # the start of the file.
      is_def = body_is_def?(state, body)
      ns = is_def ? @def_map.namespace_at(state.id, body.range.start) : Semantics::DefMap::PROGRAM
      info = @def_map[ns]
      self_t = self_type(ns)
      # A def's own `forall` vars are type params inside it.
      free = [] of String
      if node = state.tree.root.descendant(body.range.start, body.range.start + 1)
        while n = node
          if n.kind.method_def?
            n.field(Syntax::Field::Forall).try { |f| free.concat(f.named_children.map(&.text)) }
            # `def self.x`: self is the metaclass.
            if n.fields(Syntax::Field::ClassNode).any?(&.named?) && !self_t.nil?
              self_t = @table.metaclass(self_t)
            end
            break
          end
          node = n.parent
        end
      end
      ctx = Types::DefContext.new(ns, self_t, info.type_params + free)
      inf = Types::Infer.new(body, ctx, @table)
      inf.source_loader = ->(site : Semantics::Site) { def_node(site) }
      inf.summaries = @summaries
      inf.current_def = def_site(state, ns, body.range)
      unless is_def
        # File-level body: inside `class Foo ... end` self is `Foo.class`.
        file = state.id
        inf.type_body_self = ->(offset : UInt32) do
          tns = @def_map.namespace_at(file, offset)
          tns == Semantics::DefMap::PROGRAM ? nil.as(Types::TyId?) : @table.metaclass(self_type(tns)).as(Types::TyId?)
        end
        inf.type_body_ns = ->(offset : UInt32) { @def_map.namespace_at(file, offset) }
      end
      inf.with_source(state.text).run
    end

    private def ends_in_new?(site : Semantics::Site) : Bool
      node = def_node(site) || return false
      body = node.field(Syntax::Field::Body) || return false
      last = body.named_children.reject(&.kind.comment?).last? || return false
      (last.kind.call? && last.field(Syntax::Field::Receiver).nil? && last.field_text(Syntax::Field::Method) == "new") ||
        (last.kind.identifier? && last.text == "new")
    end

    # The DefMap site of the def whose body spans *range*.
    private def def_site(state : FileState, ns : Semantics::TypeId, range : TextRange) : Semantics::Site?
      @def_map[ns].members.each_value do |sites|
        sites.each { |s| return s if s.file == state.id && s.item.range == range && s.item.kind.def? }
      end
      nil
    end

    private def body_is_def?(state : FileState, body : HIR::Body) : Bool
      node = state.tree.root.descendant(body.range.start, body.range.end) || return false
      node.kind.method_def? || node.kind.abstract_method_def?
    end

    def self_type(ns : Semantics::TypeId) : Types::TyId
      return @table.unknown if ns == Semantics::DefMap::PROGRAM
      info = @def_map[ns]
      if info.kind.module? || info.kind.lib?
        # Instance methods of a module run on includers: unknown self, but
        # its own methods are still found via `extend self`-style lookups.
        return @table.named(ns, info.type_params.map { |p| @table.type_param(p) })
      end
      @table.named(ns, info.type_params.map { |p| @table.type_param(p) })
    end

    # CST node of the def at *site*. Open files use their tree; other files
    # are read and only the def's own byte range is parsed (included
    # ranges), so summarising `String.new` does not parse all of string.cr.
    private def def_node(site : Semantics::Site) : Syntax::Node?
      r = site.item.range
      tree = if state = @vfs.file?(@vfs.uri(site.file))
               state.tree
             else
               key = {site.file, r.start}
               @trees[key]? || begin
                 text = file_text(site.file) || return nil
                 return nil if r.end > text.bytesize
                 @trees.shift if @trees.size >= MAX_TREES
                 @trees[key] = @parser.parse_ranges(text, [r])
               end
             end
      node = tree.root.descendant(r.start, r.end)
      while n = node
        return n if (n.kind.method_def? || n.kind.const_assign?) && n.range == r
        node = n.parent
      end
      nil
    end

    @texts = {} of FileId => String

    private def file_text(file : FileId) : String?
      @texts[file]? || begin
        path = VFS.path_for(@vfs.uri(file)) || return nil
        return nil unless File.file?(path)
        @texts.shift if @texts.size >= MAX_TREES
        @texts[file] = File.read(path)
      end
    rescue IO::Error
      nil
    end
  end
end
