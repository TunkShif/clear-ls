require "../hir"
require "../vfs"

module ClearLS::IDE
  enum CursorBias
    Left  # token ending at the cursor (`foo|`)
    Right # token starting at the cursor (`|foo`)
  end

  # Executable bodies of one file revision, lowered on demand.
  #
  # Owners are `method_def` nodes. Top-level and class-body code outside
  # defs is lowered as one synthetic "file body" per namespace body, so
  # locals in scripts (`x = 1; puts x`) work too.
  class Bodies
    record Entry, node_range : TextRange, body : HIR::Body

    @cache = [] of Entry

    def initialize(@state : FileState)
    end

    # Body of the innermost def containing *offset*, else the file body.
    def at(offset : UInt32) : HIR::Body?
      node = owner_node(offset) || return nil
      if cached = @cache.find { |e| e.node_range == node.range }
        return cached.body
      end
      body = HIR::LowerBody.lower(node)
      @cache << Entry.new(node.range, body)
      body
    end

    private def owner_node(offset : UInt32) : Syntax::Node?
      root = @state.tree.root
      node = root.descendant(offset, offset)
      while n = node
        return n if n.kind.method_def?
        node = n.parent
      end
      root
    end
  end

  # Process-wide cache: one `Bodies` per file revision. Old revisions are
  # dropped when a file is edited.
  class BodyCache
    @entries = {} of FileId => {UInt64, Bodies}

    def for(state : FileState) : Bodies
      if (e = @entries[state.id]?) && e[0] == state.revision
        return e[1]
      end
      bodies = Bodies.new(state)
      @entries[state.id] = {state.revision, bodies}
      bodies
    end

    def evict(id : FileId) : Nil
      @entries.delete(id)
    end
  end

  # Local-variable features over one file.
  class Locals
    def initialize(@state : FileState, @bodies : Bodies)
    end

    # Binding + reference under the cursor. Tries the bias side first, then
    # the other, so `foo|` and `|foo` both hit.
    def binding_at(offset : UInt32, bias : CursorBias = CursorBias::Left) : {HIR::Body, HIR::Binding, HIR::Reference}?
      body = @bodies.at(offset) || return nil
      candidates = bias.left? ? [offset, offset + 1] : [offset + 1, offset]
      candidates.each do |probe|
        next if probe == 0
        body.bindings.each do |b|
          b.references.each do |r|
            return {body, b, r} if r.range.start < probe && probe <= r.range.end
          end
        end
      end
      nil
    end

    def definition(offset : UInt32) : TextRange?
      _, b, _ = binding_at(offset) || return nil
      b.name_range
    end

    # All references, declaration first; *include_decl* false drops it.
    def references(offset : UInt32, include_decl = true) : Array(HIR::Reference)
      _, b, _ = binding_at(offset) || return [] of HIR::Reference
      include_decl ? b.references : b.references.reject(&.kind.decl?)
    end

    # Highlights: writes for declarations/assignments, reads otherwise.
    def highlights(offset : UInt32) : Array(HIR::Reference)
      references(offset)
    end

    # Range of the identifier that would be renamed, if it is a local.
    def prepare_rename(offset : UInt32) : {TextRange, String}?
      _, b, r = binding_at(offset) || return nil
      {r.range, b.name}
    end

    # Edits for renaming the local under the cursor. Returns nil when the
    # new name is not a valid local identifier.
    def rename(offset : UInt32, new_name : String) : Array({TextRange, String})?
      return nil unless Locals.valid_local?(new_name)
      body, b, _ = binding_at(offset) || return nil
      edits = b.references.map { |r| {r.range, new_name} }
      # `def initialize(@x)`: the declaration range is the `x` inside `@x`;
      # renaming it would rename the ivar. Expand the param instead so the
      # ivar is kept: `@x` → `@x` with a local alias is not expressible, so
      # refuse unless only the local is affected.
      decl = b.references.find(&.kind.decl?)
      if decl && ivar_param?(decl.range)
        return nil
      end
      edits
    end

    def self.valid_local?(name : String) : Bool
      !!(name =~ /\A[a-z_][A-Za-z0-9_]*\z/) && !KEYWORDS.includes?(name)
    end

    KEYWORDS = %w(abstract alias annotation as asm begin break case class def do else elsif end ensure enum
      extend false for fun if in include instance_sizeof is_a? lib macro module next nil nil? of
      offsetof out pointerof private protected require rescue responds_to? return select self sizeof
      struct super then true type typeof uninitialized union unless until verbatim when while with yield)

    private def ivar_param?(range : TextRange) : Bool
      range.start > 0 && @state.text.byte_at(range.start - 1) == '@'.ord
    end
  end
end
