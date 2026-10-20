# Opal: Crystal LSP Semantic Architecture

Status: design proposal  
Last reviewed: 2026-09-10  
Target project: `https://github.com/TunkShif/opal`  
Target branch: the Tree-sitter-based refactor started on `dev`

## 1. Purpose

Opal should provide useful Crystal editing features without waiting for a full
Crystal compilation after every edit. The server should understand enough of
the program to answer completion, hover, signature help, and navigation
requests from incomplete source. The Crystal compiler remains authoritative for
diagnostics and final program semantics.

This document records the design decisions from the LSP architecture
discussion, the review of Opal's old pin model, and lessons from Solargraph,
Crystalline, Liger, rust-analyzer, and Roslyn.

The central recommendation is:

```text
source text
    ↓
Tree-sitter CST
    ├── item lowering ──→ pins / item HIR ──→ declaration index and DefMap
    └── body lowering ──→ body HIR ──→ CFG ──→ local type inference
                                      │
                                      └──────→ call and overload resolution
```

The LSP layer should consume a source-oriented semantic API built on these
representations. It should not inspect Tree-sitter nodes or orchestrate
individual analysis passes.

## 2. Goals and non-goals

### Goals

- Answer interactive requests from the current unsaved source.
- Preserve useful results when the source contains syntax errors.
- Build a persistent workspace model instead of compiling on each request.
- Support Crystal's overloads, optional arguments, named arguments, splats,
  blocks, generics, unions, and flow-sensitive local types.
- Return partial or ambiguous results when the available evidence does not
  select one answer.
- Keep analysis bounded so completion remains responsive.
- Reuse one semantic model across completion, hover, signature help,
  navigation, references, and rename.
- Allow compiler-derived facts to refine the approximate model.
- Keep protocol types and editor behavior outside the semantic core.

### Non-goals

- Reimplement Crystal code generation, ABI lowering, or LLVM integration.
- Match every detail of the compiler's type inference and overload ordering.
- Execute arbitrary macros in the first implementation.
- Publish approximate type errors as compiler diagnostics.
- Require a whole-workspace semantic rebuild after every edit.
- Model the entire program in SSA before basic editor features work.

## 3. Current Opal status

The old `main` branch contains a small Solargraph-inspired pin model built from
the Crystal compiler AST:

```text
NamespaceProcessor → NamespacePin[]
MethodProcessor    → MethodPin[]
AssignProcessor    → VariablePin[]
```

The base pin stores:

```crystal
name
location
Crystal::ASTNode
```

The old pins identify declarations but do not preserve method-body expressions,
resolved references, assignment values, branches, or control flow. They form a
symbol index prototype rather than a semantic body representation.

The `dev` branch at commit `812312a` removes most of the old implementation and
boots the Crystal Tree-sitter grammar. It does not yet contain a replacement
pin model, HIR, or LSP server architecture. The local checkout also contains an
untracked `vendor/` directory with Tree-sitter and Tree-sitter-Crystal build
artifacts. This document does not treat those files as committed project state.

The refactor should preserve the useful idea behind pins while replacing direct
`Crystal::ASTNode` ownership with stable semantic IDs and source pointers.

## 4. Terminology

### Source text

The authoritative bytes for one file revision. For an open document, the
editor buffer overrides the file on disk.

### CST

The Tree-sitter concrete syntax tree. It follows the grammar closely, keeps
source ranges, supports incremental reparsing, and contains missing or error
nodes for incomplete source.

### Item HIR

A lowered representation of indexable declarations:

- namespaces;
- methods;
- macros;
- constants;
- aliases;
- includes and extends;
- requires;
- instance and class variable declarations.

This document also calls item-HIR records **pins** because that term is already
present in Opal and Solargraph.

### Body HIR

A lowered representation of executable syntax inside a method, block, macro,
or top-level body. It contains expressions, statements, lexical bindings, and
resolved or unresolved references.

### DefMap

The namespace and scope model used for name lookup. It maps names to one or
more declarations and records inheritance, includes, extends, reopenings, and
visibility.

### CFG

A per-body control-flow graph derived from body HIR. It represents branches,
loops, exits, and joins independently from surface syntax.

### Inference result

Types, call candidates, name resolutions, reaching definitions, and flow facts
computed for a body.

### Semantic snapshot

An immutable view of files, syntax trees, declarations, project configuration,
and cached semantic results at one revision.

## 5. Two structural representations

Opal will keep two main structural representations, but only one is a syntax
tree.

### Tree-sitter CST: source-shaped

The CST answers questions about what the user typed:

- Which token is at this byte offset?
- Which method body contains the cursor?
- Is the cursor inside a comment or string?
- Which syntax subtree changed?
- Where are the delimiters and source ranges?
- Which nodes are missing or erroneous?

The CST should remain close to the grammar and retain incomplete syntax.

### HIR: meaning-shaped

HIR answers semantic questions:

- Which binding does this local reference use?
- What is the receiver of this call?
- Which arguments were supplied?
- Which branch refines a variable?
- Which declaration owns this body?
- Which type expression restricts this parameter?

HIR removes grammar-only wrappers and normalizes equivalent constructs.

For example:

```crystal
unless value.nil?
  value.upcase
end
```

can lower to:

```text
If
├── condition: Not(Call(LocalRef(value), "nil?"))
├── then: Call(LocalRef(value), "upcase")
└── else: Nil
```

The HIR is not a complete copy of the CST. It keeps only information needed by
semantic analysis and source mapping.

## 6. Pins are item HIR, not the whole HIR

The old Opal pins and most Solargraph pins represent declarations and indexed
semantic facts. They are closest to item HIR, a declaration index, or a symbol
table.

Pins should support:

- document and workspace symbols;
- declaration lookup;
- namespace lookup;
- method groups;
- inheritance and include lookup;
- type and method completion candidates;
- source navigation;
- documentation lookup.

Pins should not represent every assignment or expression in a method body.
Local assignments belong in body HIR:

```crystal
value = File.open(path)
```

Item-level information:

```text
MethodPin for the containing method
```

Body-level information:

```text
Assign
├── target: BindingId(value)
└── value:
    Call
    ├── receiver: TypeRef(File)
    ├── name: open
    └── args: [LocalRef(path)]
```

Storing only `VariablePin("value")` loses the expression needed for type
inference.

### Solargraph comparison

Solargraph's complete semantic system combines:

```text
pins
+ source maps
+ visible locals
+ expression chains
+ API maps
+ probing and inference
```

Some Solargraph pins, such as blocks and compound statements, overlap with
body-HIR concerns. Opal should keep a clearer boundary:

```text
pins       = durable declarations
body HIR   = executable semantics
CFG        = control-flow facts
```

## 7. Proposed top-level architecture

```text
┌──────────────────────────────────────────────────────────────────────┐
│ LSP transport                                                        │
│ JSON-RPC framing, lifecycle, request IDs, cancellation, capabilities │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────────────┐
│ LSP dispatcher and adapters                                          │
│ LSP positions ↔ byte offsets, protocol types ↔ IDE API types         │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────────────┐
│ IDE API                                                              │
│ complete, hover, definition, signature_help, references, rename      │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────────────┐
│ Semantic query database                                              │
│ parse, collect_items, def_map, lower_body, infer_body, resolve_call  │
└───────────────┬──────────────────────┬───────────────────────────────┘
                │                      │
┌───────────────▼────────────┐  ┌──────▼───────────────────────────────┐
│ Declaration semantics      │  │ Body semantics                      │
│ pins, scopes, DefMap,      │  │ body HIR, CFG, local inference,     │
│ method groups, hierarchy   │  │ call resolution, reaching defs      │
└───────────────┬────────────┘  └──────┬───────────────────────────────┘
                │                      │
┌───────────────▼──────────────────────▼───────────────────────────────┐
│ Syntax and source maps                                               │
│ Tree-sitter CST, SyntaxPtr, HIR source maps, line index              │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────────────┐
│ VFS and project model                                                │
│ FileId, overlays, disk state, requires, shard roots, compiler config │
└──────────────────────────────────────────────────────────────────────┘
```

The compiler integration runs beside the approximate semantic engine:

```text
Crystal compiler
    ├── diagnostics
    ├── authoritative types when available
    ├── expanded/generated declarations when available
    └── semantic summaries
             ↓
      query database refinement
```

## 8. Suggested package layout

The exact Crystal module names can change, but dependencies should point
downward:

```text
src/opal/
├── protocol/
│   ├── transport.cr
│   ├── json_rpc.cr
│   ├── lifecycle.cr
│   └── capabilities.cr
├── lsp/
│   ├── dispatcher.cr
│   ├── position_adapter.cr
│   └── handlers/
├── ide/
│   ├── completion.cr
│   ├── hover.cr
│   ├── navigation.cr
│   ├── signature_help.cr
│   ├── references.cr
│   └── rename.cr
├── workspace/
│   ├── project.cr
│   ├── project_graph.cr
│   ├── require_resolver.cr
│   └── snapshot.cr
├── vfs/
│   ├── file_id.cr
│   ├── vfs.cr
│   ├── overlay.cr
│   └── line_index.cr
├── syntax/
│   ├── parser.cr
│   ├── syntax_kind.cr
│   ├── syntax_ptr.cr
│   ├── typed_nodes/
│   └── queries/
├── hir/
│   ├── ids.cr
│   ├── item.cr
│   ├── body.cr
│   ├── expression.cr
│   ├── binding.cr
│   ├── type_expr.cr
│   ├── source_map.cr
│   └── lower/
├── semantics/
│   ├── def_map.cr
│   ├── scopes.cr
│   ├── names.cr
│   ├── method_group.cr
│   ├── hierarchy.cr
│   ├── type.cr
│   ├── cfg.cr
│   ├── inference.cr
│   ├── call_resolution.cr
│   └── summaries.cr
├── db/
│   ├── database.cr
│   ├── query.cr
│   ├── cache.cr
│   └── invalidation.cr
└── compiler/
    ├── diagnostics.cr
    ├── semantic_import.cr
    └── process.cr
```

The semantic packages must not import LSP protocol types.

## 9. Stable IDs and source identity

Do not use paths, names, or Tree-sitter node handles as semantic identity.

Suggested IDs:

```crystal
alias FileId = UInt32
alias DefId = UInt32
alias BodyId = UInt32
alias ExprId = UInt32
alias StmtId = UInt32
alias BindingId = UInt32
alias ScopeId = UInt32
alias TypeId = UInt32
```

The actual implementation can wrap these aliases in structs for type safety.

### Source pointers

HIR and pins should keep source pointers rather than raw Tree-sitter nodes:

```crystal
struct TextRange
  getter start_byte : UInt32
  getter end_byte : UInt32
end

struct SyntaxPtr
  getter file : FileId
  getter range : TextRange
  getter kind : SyntaxKind
end
```

A raw `TreeSitter::Node` belongs to a particular tree revision. Holding it
inside long-lived semantic objects risks stale-node and lifetime bugs after
incremental reparsing.

### Declaration identity and reopenings

Crystal permits a type to be reopened:

```crystal
class Widget
  def first
  end
end

class Widget
  def second
  end
end
```

Represent this as:

```text
TypeDefId Widget
├── DeclarationSite(file_a, range_a)
└── DeclarationSite(file_b, range_b)
```

Do not assign two unrelated semantic type identities merely because there are
two syntax declarations.

## 10. VFS and document snapshots

The VFS owns file identity and content. Open-document content must override
disk content.

```crystal
abstract class Vfs
  abstract def intern(uri : URI) : FileId
  abstract def uri(file : FileId) : URI
  abstract def read(file : FileId) : Bytes?
  abstract def set_overlay(file : FileId, text : String, version : Int32)
  abstract def clear_overlay(file : FileId)
end
```

The implementation should retain the URI supplied by the client for replies
while using a normalized internal identity for deduplication.

Each request captures an immutable snapshot:

```crystal
struct Snapshot
  getter revision : UInt64
  getter files : FileSnapshotStore
  getter projects : ProjectGraph
  getter database : SemanticDatabase
end
```

Document notifications apply in order. Read requests can run concurrently
against captured snapshots.

### Position handling

Keep byte offsets internally because Tree-sitter uses bytes. Convert LSP
positions at the protocol boundary using a per-file line index:

```text
LSP UTF-16 position
    ↔ line index
byte offset
```

Do not repeat UTF-16 conversion in each feature handler.

## 11. Syntax layer

Wrap Tree-sitter nodes in a typed syntax facade. Semantic code should not
compare raw node-type strings throughout the project.

```crystal
module Syntax
  struct MethodDef
    getter node : TreeSitter::Node

    def name : Token?
    def parameters : ParameterList?
    def body : Node?
    def receiver : Node?
  end
end
```

The facade should provide:

- typed child access;
- source ranges;
- missing/error checks;
- token lookup at an offset;
- ancestor traversal;
- stable `SyntaxPtr` construction.

Tree-sitter queries can help collect declarations and syntax categories, but
the query captures should feed typed lowering code. They should not become the
semantic model themselves.

### Incremental parse sequence

For a ranged edit:

1. Convert the LSP range to old byte offsets and Tree-sitter points.
2. Apply the text edit to the document.
3. Edit the old Tree-sitter tree with `TSInputEdit`.
4. Parse the new text using the edited old tree.
5. Record changed ranges.
6. Invalidate declarations or bodies intersecting those ranges.

Start with full-text synchronization if necessary, but design the document
model so ranged edits can be added without replacing every layer.

## 12. Item HIR and pins

Pins should represent declarations that the workspace can index.

### Common pin data

```crystal
abstract struct Pin
  getter id : DefId
  getter name : Name
  getter source : SyntaxPtr
  getter owner : DefId?
  getter visibility : Visibility
  getter docs : DocId?
end
```

Do not add methods such as `completion_item_kind` to pins. The LSP adapter maps
semantic kinds to protocol kinds.

### Namespace pin

```crystal
struct NamespacePin < Pin
  getter kind : NamespaceKind
  getter declared_path : NamePath
  getter superclass : TypeExprId?
  getter body_scope : ScopeId
  getter declaration_sites : Array(SyntaxPtr)
end

enum NamespaceKind
  Class
  Struct
  Module
  Enum
  Annotation
  Lib
end
```

### Method pin

```crystal
struct MethodPin < Pin
  getter kind : MethodKind
  getter params : Array(ParamDecl)
  getter return_restriction : TypeExprId?
  getter block_restriction : TypeExprId?
  getter free_vars : Array(TypeVarId)
  getter body : BodyId?
end

enum MethodKind
  Instance
  Class
  Constructor
  TopLevel
  Macro
  Extern
end
```

### Parameters

Defaults and splats are parameter properties. Do not expand them into
synthetic overload declarations.

```crystal
struct ParamDecl
  getter binding : BindingId
  getter external_name : Name?
  getter internal_name : Name
  getter restriction : TypeExprId?
  getter default_value : ExprId?
  getter kind : ParamKind
end

enum ParamKind
  Positional
  Splat
  DoubleSplat
  Block
end
```

### Other pins

Useful declaration records include:

```text
ConstantPin
AliasPin
InstanceVariablePin
ClassVariablePin
IncludePin
ExtendPin
RequirePin
MacroPin
ExternPin
```

Local variables and block parameters should normally be body bindings rather
than workspace pins.

## 13. DefMap and scope model

The DefMap answers name-resolution questions without inspecting method bodies.

```crystal
struct DefMap
  getter scopes : Arena(Scope)
  getter root : ScopeId
end

struct Scope
  getter parent : ScopeId?
  getter declarations : Hash(Name, Array(DefId))
  getter imports : Array(ImportEdge)
end
```

The declaration array preserves overloads and reopenings.

The model should cover:

- lexical namespace lookup;
- absolute paths starting with `::`;
- nested type lookup;
- top-level declarations;
- inheritance;
- included modules;
- extended modules;
- aliases;
- visibility;
- requires and project boundaries.

Use IDs as identity and qualified names as derived lookup keys.

## 14. Method groups and overloads

Group declarations by owner, method kind, and name:

```crystal
struct MethodGroup
  getter owner : DefId
  getter kind : MethodKind
  getter name : Name
  getter declarations : Array(DefId)
end
```

For `IO#gets`, one group contains all source declarations:

```crystal
gets(delimiter : Char, limit : Int, chomp = false)
gets(chomp : Bool = true)
gets(limit : Int, chomp : Bool = false)
gets(delimiter : Char, chomp : Bool = false)
gets(delimiter : String, chomp = false)
```

Do not choose a declaration until call-site evidence supports the choice.

## 15. Body HIR design

Lower each executable body into independently addressable arenas:

```crystal
struct Body
  getter id : BodyId
  getter owner : DefId
  getter root : ExprId
  getter expressions : Arena(Expr)
  getter statements : Arena(Stmt)
  getter bindings : Arena(Binding)
  getter scopes : Arena(BodyScope)
  getter source_map : BodySourceMap
end
```

Bodies should be lowered on demand and cached by the syntax subtree identity or
content fingerprint.

### Bindings

```crystal
struct Binding
  getter id : BindingId
  getter name : Name
  getter kind : BindingKind
  getter scope : ScopeId
  getter declaration : SyntaxPtr
  getter restriction : TypeExprId?
end

enum BindingKind
  Parameter
  BlockParameter
  Local
  RescueVariable
end
```

Every local reference should point to a `BindingId` when lexical resolution
succeeds.

### Expressions

A practical initial expression set:

```crystal
abstract struct Expr
end

struct MissingExpr < Expr
end

struct LiteralExpr < Expr
  getter literal : Literal
end

struct LocalRefExpr < Expr
  getter binding : BindingId?
  getter unresolved_name : Name?
end

struct SelfExpr < Expr
end

struct InstanceVarExpr < Expr
  getter name : Name
end

struct ClassVarExpr < Expr
  getter name : Name
end

struct ConstRefExpr < Expr
  getter path : NamePath
  getter resolution : DefId?
end

struct AssignExpr < Expr
  getter target : AssignTarget
  getter value : ExprId
end

struct CallExpr < Expr
  getter receiver : ExprId?
  getter name : Name
  getter positional_args : Array(ExprId)
  getter named_args : Array(NamedArg)
  getter block : ExprId?
end

struct BlockExpr < Expr
  getter params : Array(BindingId)
  getter body : ExprId
end

struct IfExpr < Expr
  getter condition : ExprId
  getter then_branch : ExprId
  getter else_branch : ExprId?
end

struct CaseExpr < Expr
  getter subject : ExprId?
  getter branches : Array(CaseBranch)
  getter else_branch : ExprId?
end

struct LoopExpr < Expr
  getter condition : ExprId
  getter body : ExprId
  getter kind : LoopKind
end

struct ReturnExpr < Expr
  getter value : ExprId?
end

struct BreakExpr < Expr
  getter value : ExprId?
end

struct NextExpr < Expr
  getter value : ExprId?
end

struct YieldExpr < Expr
  getter args : Array(ExprId)
end

struct TypeTestExpr < Expr
  getter value : ExprId
  getter target : TypeExprId
end

struct CastExpr < Expr
  getter value : ExprId
  getter target : TypeExprId
  getter nilable : Bool
end
```

Add syntax-specific variants only when downstream semantics need the
distinction.

### Incomplete source

Lower missing or malformed syntax to explicit unknown nodes:

```text
MissingExpr
UnknownExpr
MalformedCall
```

One malformed expression must not prevent lowering the rest of the containing
body.

## 16. HIR source maps

HIR no longer mirrors source syntax, so maintain mappings in both directions:

```crystal
struct BodySourceMap
  getter expr_sources : Hash(ExprId, SyntaxPtr)
  getter binding_sources : Hash(BindingId, SyntaxPtr)
  getter syntax_exprs : Hash(SyntaxPtr, ExprId)
end
```

This supports:

```text
LSP position
→ byte offset
→ CST node
→ SyntaxPtr
→ ExprId or BindingId
→ semantic result
```

and:

```text
DefId or BindingId
→ SyntaxPtr
→ byte range
→ LSP location
```

Source maps should also support synthetic declarations generated from known
macros by pointing back to the macro invocation and, when useful, the macro
definition.

## 17. Structured type representation

Do not use formatted strings as the primary semantic type representation.

```crystal
abstract struct Type
end

struct NamedType < Type
  getter definition : DefId
  getter args : Array(TypeId)
end

struct UnionType < Type
  getter members : Array(TypeId)
end

struct TypeVar < Type
  getter id : TypeVarId
end

struct ProcType < Type
  getter params : Array(TypeId)
  getter result : TypeId
end

struct MetaclassType < Type
  getter instance : TypeId
end

struct TupleType < Type
  getter elements : Array(TypeId)
end

struct NamedTupleType < Type
  getter fields : Array({Name, TypeId})
end

struct UnknownType < Type
  getter reason : UnknownReason
end
```

Intern canonical types to obtain cheap equality and compact sets.

### Open type sets

Unknown information should not behave as universal `Object`.

```crystal
struct TypeSet
  getter members : SmallSet(TypeId)
  getter open : Bool
end
```

Examples:

```text
{String}, open=false         exact String
{String, Nil}, open=false    closed union
{IO}, open=true              IO or an unknown subtype
{}, open=true                unknown
{}                           impossible/unreachable
```

### Certainty and provenance

```crystal
struct TypeResult
  getter types : TypeSet
  getter certainty : Certainty
  getter evidence : Array(Evidence)
  getter reasons : Array(UnknownReason)
end
```

Features can apply different confidence thresholds:

| Feature | Acceptable confidence |
|---|---|
| Completion | approximate |
| Signature help | approximate candidate set |
| Hover | approximate, identified as such |
| Definition | multiple plausible locations |
| References | narrowed or better |
| Rename | strongly resolved |
| Diagnostics | compiler result only |

## 18. CFG and local flow analysis

Start by implementing transfer functions over structured HIR. Move them onto
an explicit CFG when loops, exits, and query-at-position behavior become
difficult to maintain.

The intended steady-state design is a small non-SSA CFG:

```crystal
struct BasicBlock
  getter id : BlockId
  getter operations : Array(Operation)
  getter terminator : Terminator
  getter predecessors : Array(BlockId)
  getter successors : Array(BlockId)
end
```

Typical terminators:

```text
Jump
Branch
Return
Break
Next
Raise
Unreachable
```

### Dataflow state

```crystal
struct Environment
  getter bindings : PersistentMap(BindingId, TypeFact)
  getter reachable : Bool
end
```

The forward analysis equations are:

```text
IN[block]  = join(OUT[pred] for each reachable predecessor)
OUT[block] = transfer(block, IN[block])
```

Use a worklist until states stop changing or an analysis budget is reached.

### Joins

At a branch join:

```crystal
if cond
  value = 1
else
  value = "one"
end
```

the result is:

```text
value → Int32 | String
```

Unreachable predecessors do not contribute:

```crystal
if value.is_a?(String)
  return
else
  value = 1
end

# value → Int32
```

### Edge refinements

Conditions produce facts on outgoing edges:

```crystal
if value.is_a?(String)
```

```text
true edge:  value := intersect(value, String)
false edge: value := subtract(value, String)
```

Likewise for:

- truthiness;
- `nil?`;
- `responds_to?`;
- `case` type branches;
- `!`;
- short-circuit `&&` and `||`.

### Loops

Loops require fixed-point iteration because the body feeds facts back to the
condition:

```text
preheader → condition → body
                ↑         │
                └─────────┘
```

Set limits:

```text
maximum loop iterations
maximum union members
maximum recursive summary depth
maximum query duration
```

When a limit is reached, widen the result and record an uncertainty reason.

### Program-point results

Store block-entry environments and replay operations to the cursor, or cache
selected program-point environments. Completion needs the type state at the
cursor rather than only at the end of a body.

## 19. Type inference

Implement inference in tiers.

### Tier 1: local and explicit facts

- literal types;
- annotations;
- casts;
- constructors;
- array, hash, tuple, and named-tuple literals;
- assignment propagation;
- branch unions;
- nil and type-test narrowing;
- declared method returns;
- parameter restrictions.

### Tier 2: method summaries

Compute bounded summaries:

```crystal
struct MethodSummary
  getter return_types : TypeResult
  getter yields : Array(TypeResult)
  getter mutations : Array(Mutation)
  getter completeness : Completeness
end
```

Analyze summaries on demand and guard recursion:

```text
Unvisited → Computing → Complete
                    ↘ RecursiveApproximation
```

### Tier 3: generic substitution

Unify declared restrictions with actual types:

```crystal
def first(values : Array(T)) : T
end

first(["a"])
```

```text
Array(T) ~ Array(String)
T = String
return T → String
```

Unsupported restrictions should produce an uncertain match rather than a
false rejection.

### Tier 4: compiler refinement

Import facts from the real compiler when available:

- instantiated method return types;
- ivar and cvar types;
- generated declarations;
- resolved overload targets;
- macro expansions.

Compiler facts take precedence for the exact project configuration and source
revision that produced them.

## 20. Call and overload resolution

Use one resolver for completion, hover, signature help, definition,
references, and rename:

```crystal
def resolve_call(
  snapshot : Snapshot,
  body : BodyId,
  call : ExprId,
  mode : ResolutionMode
) : CallResolution
```

Resolution stages:

```text
receiver type candidates
    ↓
method group lookup
    ↓
argument-to-parameter binding
    ↓
type compatibility
    ↓
specificity ranking
    ↓
resolution with confidence
```

### Structural argument binding

Account for:

- required positional arguments;
- optional/defaulted arguments;
- named arguments;
- splats;
- double splats;
- block presence and restrictions.

Do not require argument types for this stage.

### Type compatibility

Use three-valued compatibility:

```crystal
enum Compatibility
  Compatible
  Incompatible
  Unknown
end
```

Eliminate a candidate only after proving incompatibility. Missing information
must preserve candidates.

### Resolution result

```crystal
struct CallResolution
  getter kind : ResolutionKind
  getter candidates : Array(CallCandidate)
end

enum ResolutionKind
  Unique
  MultipleRuntimeTargets
  Ambiguous
  NameOnly
  Unresolved
end
```

### `IO#gets`

For:

```crystal
io.gets(10)
```

literal inference can select:

```crystal
gets(limit : Int, chomp : Bool = false)
```

For:

```crystal
io.gets(value)
```

with unknown `value`, retain every structurally viable overload. Hover and
signature help can show the family; goto definition can return all plausible
locations. Rename should refuse to act unless identity is stronger.

## 21. LSP feature policies

### Completion

Member-name completion should normally group overloads into one item:

```text
gets    method, 5 overloads
```

Insert only `gets`. Signature help presents overload-specific parameter lists
after `(`.

Named-argument completion uses the viable candidate set:

```crystal
io.gets(li|)
```

can offer:

```text
limit:
```

### Signature help

Return all viable signatures:

```text
signatures       = candidate declarations
activeSignature  = best supported candidate
activeParameter  = parameter bound to the cursor argument
```

Keep all candidates when types are unknown.

### Hover

Hover can show:

- declaration signature;
- possible expression types;
- method overload family;
- documentation;
- an approximation note when useful.

Example:

```text
value : String | Nil
inferred from branch assignments
```

### Goto definition

Fallback order:

1. exact resolved declaration;
2. all viable overload declarations;
3. possible targets from union receiver members;
4. lexical and namespace candidates;
5. bounded project-index lookup;
6. no result.

Do not choose a random source-order declaration.

### References

Start with exact local bindings because `BindingId` makes them reliable.

Workspace references should require resolved `DefId` identity. Textual matches
can appear as an optional broad search, not as semantic references.

### Rename

Rename requires stronger evidence than navigation:

- local binding rename: exact `BindingId`;
- method/type rename: resolved `DefId` and references;
- ambiguous or macro-generated identity: reject or request confirmation.

### Diagnostics

Use the Crystal compiler for syntax and semantic diagnostics. Tree-sitter error
nodes may support internal status or parser debugging, but Opal should not
publish approximate overload or type errors as compiler truth.

## 22. Macro strategy

Complete Crystal semantics eventually require macro execution. Do not make
general macro evaluation a prerequisite for useful editing.

Implement three levels.

### Level 1: visible macro declarations

Index macro names, parameters, docs, and source locations.

### Level 2: known declarative macros

Provide plugins or summaries for predictable generators:

```text
getter
setter
property
record
delegate
forward_missing_to
JSON::Serializable
```

Synthetic declarations should point to the invocation that generated them.

### Level 3: compiler-derived expansions

Run the Crystal compiler in the background and import generated declarations
or semantic summaries. Cache by:

```text
compiler version
project flags
dependency graph
source revisions
```

## 23. Query database and invalidation

Semantic operations should be demand-driven queries:

```text
parse(FileId)
collect_items(FileId)
project_def_map(ProjectId)
lower_body(BodyId)
body_cfg(BodyId)
infer_body(BodyId)
resolve_name(ScopeId, Name)
methods_of(TypeId, Name)
resolve_call(BodyId, ExprId)
method_summary(DefId, Substitution)
```

Each query records dependencies. An edit should invalidate affected facts:

```text
body-only edit
    → parse changed file
    → invalidate changed BodyId
    → invalidate its inference and dependents

method-signature edit
    → update item HIR
    → invalidate method group and callers

namespace/include edit
    → invalidate affected DefMap and method lookup queries
```

The first implementation can use explicit versioned caches instead of a full
Salsa-like engine. Preserve query boundaries so dependency tracking can improve
without rewriting feature handlers.

## 24. Concurrency and cancellation

Process document mutations in arrival order:

```text
didOpen
didChange
didClose
workspace-folder changes
```

Read requests capture one immutable snapshot and run concurrently.

Track request cancellation:

```text
request ID → cancellation token
```

Long-running operations should check cancellation at:

- workspace scans;
- body lowering;
- CFG worklist iterations;
- hierarchy traversal;
- recursive summary evaluation;
- compiler process waits.

If the document changes while a request is running, discard the stale result or
return `ContentModified`.

## 25. Project and require model

LSP workspace folders are not Crystal project roots. Discover projects from:

- `shard.yml`;
- configured entry points;
- source roots;
- required shard sources;
- compiler flags.

Support:

- multiple projects in one workspace folder;
- orphan files outside project roots;
- single-file mode;
- files not yet required by an entry point;
- multiple open unsaved files;
- changing workspace folders.

Require resolution belongs in the project model:

```text
requiring file directory
project source roots
shard lib roots
Crystal standard library roots
configured CRYSTAL_PATH
```

The workspace index should not depend on whether the compiler has already
reached a file. Parse-only indexing can expose declarations before a successful
compile.

## 26. Lessons from existing implementations

### Solargraph

Useful ideas:

- pins as semantic declaration facts;
- closure ancestry;
- separate lexical context and binder context;
- source maps;
- combining declarations from source, docs, and external type information;
- expression-chain queries.

Do not copy:

- raw parser nodes as long-lived semantic identity;
- one large pin hierarchy for declarations, flow, docs, and LSP conversion;
- qualified strings as primary identity;
- cursor-time parsing as the only body representation.

### Crystalline

Useful ideas:

- project index plus current-file overlay;
- compiler-derived semantic summaries;
- source-first results while compilation runs;
- local branch narrowing;
- generic substitution;
- block contracts;
- standard-library prelude cache;
- extensive incomplete-source tests.

Limits to avoid:

- string-only type representation;
- one large cursor-oriented inference walker;
- textual receiver-chain reconstruction as the main call representation;
- per-document overlays without a workspace-wide snapshot;
- coarse overload selection.

### Liger

Useful ideas:

- compiler tool commands as optional fallback;
- C `lib` and `fun` support;
- signature-help protocol integration;
- cross-platform path concerns.

Do not use as the semantic foundation:

- regex-based workspace parsing;
- hard-coded method inventories;
- whole-workspace rescans on edits;
- approximate semantic diagnostics;
- single-result method lookup;
- textual rename presented as semantic rename.

### rust-analyzer and Roslyn

The target architecture is closer to rust-analyzer:

- independent IDE frontend;
- persistent semantic database;
- incomplete-source tolerance;
- demand-driven body inference;
- compiler remains authoritative.

Borrow Roslyn's data-model principles:

- immutable syntax snapshots;
- stable symbols;
- explicit semantic models;
- source mappings;
- common semantic services shared by all editor features.

## 27. Implementation roadmap

### Phase 0: foundations

- Define `FileId`, `TextRange`, `SyntaxPtr`, and line indexes.
- Implement VFS overlays.
- Implement immutable snapshots.
- Wrap Tree-sitter nodes in typed syntax accessors.
- Add incremental parse tests.

Exit criterion:

```text
open/edit/close preserves exact text and byte/LSP position conversions;
Tree-sitter reparses edited files without rebuilding unrelated files.
```

### Phase 1: item collection

- Lower namespaces, methods, constants, aliases, includes, extends, and
  requires into pins.
- Support reopened types.
- Build per-file item indexes and a project DefMap.
- Add document and workspace symbol features.

Exit criterion:

```text
declarations and source locations remain correct across nested namespaces,
reopenings, files, and incremental edits.
```

### Phase 2: lexical body HIR

- Lower one method body on demand.
- Create scopes and `BindingId`s.
- Resolve locals, parameters, and block parameters.
- Implement local goto-definition and exact local rename.

Exit criterion:

```text
shadowed locals and block parameters resolve to the correct declaration.
```

### Phase 3: initial type inference

- Infer literals, annotations, constructors, assignments, and declared method
  returns.
- Add structured `TypeId` and `TypeSet`.
- Add completion and hover for straightforward receiver types.

Exit criterion:

```text
common local and ivar receiver completions work without compiler invocation.
```

### Phase 4: control-flow analysis

- Build the per-body CFG.
- Add branch joins, reachability, truthiness, nil narrowing, `is_a?`, `case`,
  and loop fixed points.
- Expose the environment at a cursor program point.

Exit criterion:

```text
completion and hover reflect branch-local and post-branch union types.
```

### Phase 5: method groups and call resolution

- Implement structural argument binding.
- Support defaults, named arguments, splats, double splats, and blocks.
- Add three-valued type compatibility.
- Add bounded specificity ranking.
- Implement signature help and overload-aware goto-definition.

Exit criterion:

```text
the IO#gets examples narrow to the expected overload set without guessing
when argument types are unknown.
```

### Phase 6: generics and summaries

- Add generic type substitution.
- Infer method return summaries on demand.
- Add recursion guards and widening.
- Model common collection/block contracts.

Exit criterion:

```text
Array(T), Hash(K, V), tuple, block, map, compact_map, find, and reduce chains
retain useful concrete types.
```

### Phase 7: compiler refinement and macros

- Run compiler diagnostics asynchronously.
- Import semantic summaries.
- Add known macro plugins.
- Map compiler-generated declarations back to source.

Exit criterion:

```text
compiler facts improve semantic results without blocking normal requests.
```

### Phase 8: workspace references and rename

- Build a reference index keyed by `DefId`.
- Update it incrementally.
- Require exact or strongly narrowed identity for rename.

Exit criterion:

```text
workspace rename does not edit unrelated same-name symbols.
```

## 28. Testing strategy

### Syntax and lowering tests

Use source fixtures and snapshot:

- CST kinds and ranges where grammar behavior matters;
- collected pins;
- body HIR;
- source maps;
- error-node lowering.

### Resolution tests

Cover:

- nested namespaces;
- absolute and relative paths;
- reopenings;
- includes and extends;
- aliases;
- shadowed locals;
- implicit self calls;
- inherited methods.

### CFA tests

Cover:

- branch unions;
- `is_a?`;
- nil checks;
- truthiness;
- `&&` and `||`;
- `case`;
- return and unreachable branches;
- loops and widening;
- rescue paths;
- block scopes.

### Overload tests

Use `IO#gets` as a standing regression family:

```crystal
io.gets
io.gets(false)
io.gets(10)
io.gets('x')
io.gets("END")
io.gets('x', 100)
io.gets(100, true)
io.gets('x', true)
io.gets("END", true)
io.gets('x', 100, true)
io.gets(value)
```

Test both exact and unknown argument types.

### Differential tests

For valid complete fixtures:

1. Ask Opal for inferred types and call targets.
2. Ask the Crystal compiler for the corresponding facts when accessible.
3. Record disagreements.

Do not require complete equality. Classify disagreements as:

```text
expected approximation
unsupported feature
Opal bug
compiler-version difference
```

### Performance tests

Measure:

- parse time after one ranged edit;
- item recollection time;
- body lowering time;
- inference p50 and p95;
- completion p50 and p95;
- cache hit rates;
- invalidated query count per edit;
- union widening frequency.

Correctness tests run before performance tests.

## 29. Design rules

1. Tree-sitter nodes stay in the syntax layer.
2. Pins identify declarations; body HIR represents execution.
3. Semantic identity uses IDs, not names or paths.
4. Open buffers override disk content.
5. One request observes one immutable snapshot.
6. Unknown information preserves candidates.
7. Only proven incompatibility removes an overload.
8. Completion prefers recall; rename prefers precision.
9. The compiler owns diagnostics.
10. Analysis has explicit time, recursion, and union-size budgets.
11. LSP types do not enter the semantic core.
12. Feature handlers call shared queries instead of implementing separate
    inference rules.
13. Current implementation status and proposed design remain clearly
    separated in documentation.

## 30. Early decisions still required

The implementation should settle these choices before the HIR grows:

### Crystal implementation language

The current project uses Crystal. That gives direct access to the existing
Tree-sitter Crystal binding and keeps distribution simple, but the query cache,
immutable snapshots, and arena APIs will need careful ownership conventions.

### Query engine

Options:

- explicit versioned memoization;
- a small custom dependency graph;
- an available incremental-query library.

Start with explicit query objects and dependencies. Avoid hiding analysis
behind global mutable caches.

### Pin naming

Two reasonable vocabularies:

```text
Pin = declaration record
Body HIR = executable representation
```

or:

```text
Item HIR = declaration record
Body HIR = executable representation
```

Keeping `Pin` is acceptable if the boundary remains clear.

### Parser error strategy

Decide which malformed nodes lower to:

- missing expressions;
- unknown calls;
- partial paths;
- synthetic placeholders.

The policy should preserve surrounding declarations and control flow.

### Compiler integration

Decide whether to:

- embed Crystal compiler APIs;
- invoke `crystal tool` subprocesses;
- support both behind one interface.

The semantic core should not depend on the chosen transport.

## 31. Recommended next implementation slice

The next slice should prove the representation boundaries without attempting
type inference:

1. Add `FileId`, `TextRange`, `SyntaxPtr`, and a line index.
2. Introduce a `DocumentSnapshot` containing text and Tree-sitter tree.
3. Add typed syntax wrappers for namespace and method declarations.
4. Lower namespace and method pins from one file.
5. Model reopened namespaces with one semantic identity and multiple sites.
6. Add `BodyId` and a minimal body containing literals, local references,
   assignments, calls, and blocks.
7. Add bidirectional HIR source maps.
8. Test incomplete methods and incremental edits.

Do not add completion yet. First expose a debug command or test helper that
prints:

```text
file items
method signatures
body HIR
binding IDs
source mappings
```

Once that representation is stable, local goto-definition is the first useful
LSP feature to build. It validates position conversion, syntax lookup, body
lowering, scope construction, binding resolution, and navigation without
requiring type inference.

## 32. References

- Opal repository:
  `https://github.com/TunkShif/opal`
- Solargraph `Pin::Common`:
  `https://github.com/castwide/solargraph/blob/master/lib/solargraph/pin/common.rb`
- Solargraph source-map architecture:
  `https://github.com/castwide/solargraph/tree/master/lib/solargraph/source_map`
- Crystalline:
  `https://github.com/elbywan/crystalline`
- Liger:
  `https://github.com/navid-m/liger`
- rust-analyzer architecture:
  `https://rust-analyzer.github.io/book/contributing/architecture.html`
- Language Server Protocol:
  `https://microsoft.github.io/language-server-protocol/`

