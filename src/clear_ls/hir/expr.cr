require "../base/text_range"
require "../syntax/kinds"

module ClearLS::HIR
  # Indexes into a `Body`'s arenas. Valid only for the body (and revision)
  # that produced them.
  record ExprId, value : Int32
  record BindingId, value : Int32
  record ScopeId, value : Int32

  enum BindingKind
    Param       # def parameter (incl. splat, double splat)
    BlockParam  # def `&block` parameter
    BlockArg    # `|x|` parameter of a block or proc literal
    Local       # assignment target
    RescueVar   # `rescue ex`
    TypeDecl    # `x : T = v`
    MacroVar    # `{% for x in ... %}` (not yet produced)
  end

  # A named local slot.
  #
  # `@x` params bind both the ivar (handled by the item tree) and a local
  # named `x`; the binding's `name_range` then covers only `x` in `@x`.
  class Binding
    getter id : BindingId
    getter name : String
    getter kind : BindingKind
    getter scope : ScopeId
    # Full declaring construct (param, assignment target, ...).
    getter decl_range : TextRange
    # Just the name token.
    getter name_range : TextRange
    getter restriction : String?
    # Every place this binding is read or (re)assigned, including the
    # declaration itself.
    getter references = [] of Reference

    def initialize(@id, @name, @kind, @scope, @decl_range, @name_range, @restriction)
    end
  end

  enum RefKind
    Decl  # introduces the binding
    Write # later assignment to an existing binding
    Read
  end

  record Reference, range : TextRange, kind : RefKind

  enum ScopeKind
    Def
    Block # `do |x| ... end`, `{ |x| ... }`, proc literal
  end

  # Lexical scope. Blocks see their parent's bindings; new assignments
  # inside a block create block-local bindings.
  class Scope
    getter id : ScopeId
    getter kind : ScopeKind
    getter parent : ScopeId?
    getter range : TextRange
    getter bindings = {} of String => BindingId

    def initialize(@id, @kind, @parent, @range)
    end
  end

  enum ExprKind
    Missing     # ERROR / MISSING node or unsupported construct
    Nop         # absent optional part (empty `then`/`else`, no `case` subject)
    Literal
    LocalRef    # resolved to a binding
    Self
    InstanceVar
    ClassVar
    Global
    Const       # constant path (resolution happens in semantics)
    Assign
    OpAssign
    MultiAssign
    Call        # also identifiers that are not locals (`foo` → self.foo)
    Block
    ProcLiteral
    If          # children: cond, then, else (Nop when absent)
    Unless
    Case        # children: subject (or Nop), then When / else-Seq clauses
    When        # `when`/`in` clause (syntax tells which): conditions..., body
    While
    Until
    Return
    Break
    Next
    Yield
    Begin       # body, Rescue clauses..., else Seq?, ensure Seq? (by syntax)
    Rescue      # rescue clause: binding = rescue var, type_text, children: [body]
    Seq         # statement list
    And
    Or
    Not
    TypeDecl
    Collection  # array, hash, tuple, named tuple, range
    Other       # recognised but not modelled further (lowered children only)
  end

  # One HIR expression.
  #
  # The HIR is deliberately thin in Phase 2: it exists to carry scopes,
  # bindings, and source maps; types and control flow arrive later. Fields
  # are generic (`name`, `children`, ...) rather than one class per kind.
  class Expr
    getter id : ExprId
    getter kind : ExprKind
    getter range : TextRange
    # Call / identifier / const / ivar name. For calls, the method name.
    getter name : String?
    # Range of the name token (method name, constant, ivar, ...).
    getter name_range : TextRange?
    getter binding : BindingId?
    getter receiver : ExprId?
    getter children : Array(ExprId)
    # Call arguments by name (`foo(k: v)`).
    getter named_args : Array({String, ExprId})
    getter block : ExprId?
    # Lexical scope this expression evaluates in.
    getter scope : ScopeId
    # CST kind this expression came from (literal kind, collection kind, ...).
    getter syntax : Syntax::Kind
    # Literal source text (numbers, for suffixes like `1_i64`).
    getter text : String?
    # Type written in the construct: `[] of T`, `{} of K => V`,
    # `uninitialized T`, `x.as(T)`, `is_a?(T)`, block/proc param types.
    getter type_text : String?
    # Second type for `{} of K => V`.
    getter type_text2 : String?

    def initialize(@id, @kind, @range, @scope, *, @syntax = Syntax::Kind::Unknown, @name = nil, @name_range = nil,
                   @binding = nil, @receiver = nil, @children = [] of ExprId, @named_args = [] of {String, ExprId},
                   @block = nil, @text = nil, @type_text = nil, @type_text2 = nil)
    end

    # Call with no receiver, arguments, or block: `foo`. Ambiguous between a
    # method call and an undefined local in incomplete code.
    def bare_call? : Bool
      kind.call? && receiver.nil? && children.empty? && named_args.empty? && block.nil?
    end
  end
end
