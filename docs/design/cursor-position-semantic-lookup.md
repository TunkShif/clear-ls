# Opal: Cursor Position to Semantic Data Lookup

Status: design proposal  
Last reviewed: 2026-09-11  
Companion document: `docs/opal/crystal-lsp-semantic-architecture.md`

## 1. Purpose

An LSP request identifies a document and a cursor position:

```text
DocumentURI + line + character
```

Opal must translate that protocol position into the semantic object relevant to
the request:

- a declaration;
- a local binding;
- an expression;
- a method call;
- an argument;
- a type restriction;
- a control-flow program point.

Tree-sitter provides spatial lookup in the CST with operations such as
`descendant_for_byte_range` and `descendant_for_point_range`. HIR usually has
no equivalent tree traversal because it is normalized, may have many-to-many
source mappings, and is commonly stored in arenas keyed by IDs.

Use Tree-sitter as the primary spatial syntax index and use range-indexed source
maps to bridge syntax to HIR:

```text
LSP position
    ↓
byte offset
    ↓
Tree-sitter leaf and ancestor path
    ↓
containing declaration or body
    ↓
HIR source-map hits
    ↓
ExprId / BindingId / DefId / ProgramPoint
    ↓
semantic query result
```

## 2. Representations involved

### CST

The Tree-sitter CST follows source syntax and owns:

- byte ranges;
- source points;
- tokens and grammar nodes;
- missing nodes;
- error nodes;
- parent and child relationships.

It answers:

```text
Which syntax node contains this position?
```

### Item HIR and pins

Pins identify indexable declarations:

- namespaces;
- methods;
- macros;
- constants;
- aliases;
- includes and extends;
- requires;
- instance and class variables.

They answer:

```text
Which declaration contains or owns this position?
```

### Body HIR

Body HIR represents executable semantics:

- local references;
- assignments;
- calls;
- arguments;
- blocks;
- branches;
- loops;
- exits;
- type tests and casts.

It answers:

```text
Which semantic expression, binding, or call corresponds to this syntax?
```

### CFG

The per-body CFG associates expressions and statement boundaries with analysis
program points. It answers:

```text
Which flow-sensitive environment applies at this position?
```

## 3. End-to-end lookup

Use one shared entry point for cursor-based semantic lookup:

```crystal
struct FilePosition
  getter file : FileId
  getter offset : UInt32
end

struct SemanticPosition
  getter file : FileId
  getter offset : UInt32
  getter syntax : SyntaxPtr?
  getter item : DefId?
  getter body : BodyId?
  getter expr : ExprId?
  getter binding : BindingId?
  getter scope : ScopeId?
  getter program_point : ProgramPoint?
end

def semantics_at(
  snapshot : Snapshot,
  position : FilePosition,
  bias : CursorBias = CursorBias::Left,
) : SemanticPosition
```

Feature handlers should build on this API instead of implementing separate
position lookup rules.

## 4. Convert LSP positions at the protocol boundary

LSP `Position.character` counts UTF-16 code units unless the client and server
negotiate another encoding. Tree-sitter byte columns count bytes.

Do not pass an LSP position directly to Tree-sitter.

```crystal
offset = document.line_index.byte_offset(
  line: position.line,
  utf16_column: position.character,
)
```

Keep byte offsets inside syntax and semantic layers:

```text
LSP UTF-16 position
    ↔ LineIndex
byte offset
```

The line index should also support the reverse conversion when returning LSP
locations.

## 5. Cursor positions require a bias

A cursor sits between characters, while syntax nodes cover byte ranges.

For:

```crystal
value.upcase
     ^
```

the cursor may sit:

- immediately after `value`;
- on the period;
- immediately before `upcase`;
- immediately after `upcase`.

Define an explicit bias:

```crystal
enum CursorBias
  Left
  Right
  Exact
end
```

A possible byte-based lookup:

```crystal
def syntax_node_at(
  root : TreeSitter::Node,
  offset : UInt32,
  text_size : UInt32,
  bias : CursorBias,
) : TreeSitter::Node?
  return root if text_size == 0

  case bias
  when .left?
    if offset > 0
      root.descendant(offset - 1, offset)
    else
      root.descendant(0_u32, Math.min(1_u32, text_size))
    end
  when .right?
    if offset < text_size
      root.descendant(offset, offset + 1)
    elsif offset > 0
      root.descendant(offset - 1, offset)
    end
  when .exact?
    root.descendant(offset, offset)
  end
end
```

Feature defaults:

| Feature | Preferred lookup |
|---|---|
| Hover | left, then right |
| Goto definition | left, then right |
| Rename | token under cursor, then left |
| Completion after `.` | left for the receiver, syntax context for the trigger |
| Signature help after `,` | left |
| Selection range | exact or right |

Do not force every feature to use one cursor rule.

## 6. Retrieve a syntax path, not only one node

Tree-sitter usually returns the smallest descendant containing the requested
range. That node may be:

```text
identifier
period
comma
closing parenthesis
```

Semantic lowering may map a parent node rather than the leaf. Preserve the leaf
and its ancestors:

```crystal
def syntax_path_at(
  root : TreeSitter::Node,
  offset : UInt32,
  text_size : UInt32,
  bias : CursorBias,
) : Array(TreeSitter::Node)
  path = [] of TreeSitter::Node
  node = syntax_node_at(root, offset, text_size, bias)

  while node
    path << node
    parent = node.parent
    break if parent == node
    node = parent
  end

  path
end
```

For:

```crystal
service.process(value)
```

the syntax path might contain:

```text
identifier "process"
call
expression statement
method body
method definition
class definition
source file
```

Order it from narrowest to broadest.

## 7. Find the containing declaration and body

Keep a file-level interval index:

```crystal
struct FileSemanticMap
  getter items : SpanIndex(DefId)
  getter bodies : SpanIndex(BodyId)
end
```

The lookup should select the smallest containing range:

```crystal
item = file_map.items.smallest_containing(offset)
body = file_map.bodies.smallest_containing(offset)
```

For a cursor in a method call:

```text
class declaration    broad item
method declaration   narrow item
method body           body
call expression       body-HIR hit
method-name role      narrow semantic hit
```

Item lookup must work before body HIR has been lowered. Body lookup identifies
which body should be lowered on demand.

## 8. Source pointers

Do not store long-lived `TreeSitter::Node` values inside pins or HIR.
Tree-sitter nodes belong to a particular tree revision.

Store source pointers:

```crystal
struct TextRange
  getter start_byte : UInt32
  getter end_byte : UInt32

  def contains?(offset : UInt32) : Bool
    start_byte <= offset && offset <= end_byte
  end

  def size : UInt32
    end_byte - start_byte
  end
end

struct SyntaxPtr
  getter file : FileId
  getter range : TextRange
  getter kind : SyntaxKind
end
```

Use the source pointer to recover current syntax from the same semantic
snapshot when required.

## 9. HIR source maps

Body lowering should produce a source map with forward and reverse mappings:

```crystal
struct BodySourceMap
  getter expr_sources : Hash(ExprId, HirSource)
  getter binding_sources : Hash(BindingId, HirSource)

  getter syntax_exprs : Hash(SyntaxPtr, Array(ExprId))
  getter syntax_bindings : Hash(SyntaxPtr, Array(BindingId))

  getter spans : SpanIndex(HirHit)
end
```

Reverse mappings return arrays because lowering is not necessarily one-to-one.

One syntax node can produce multiple HIR expressions:

```crystal
unless condition
  body
end
```

can produce:

```text
Not(condition)
If(Not(condition), body, Nil)
```

Synthetic HIR can also map to a macro invocation or another source anchor.

## 10. Record semantic roles

The whole-expression range is not enough.

For:

```crystal
receiver.method(first, name: second)
^^^^^^^^  ^^^^^^ ^^^^^  ^^^^ ^^^^^^
```

the cursor can identify:

- the receiver expression;
- the selected method name;
- a positional argument;
- a named-argument label;
- a named-argument value.

Represent these roles:

```crystal
enum SourceRole
  Whole
  Name
  Receiver
  Argument
  NamedArgumentName
  NamedArgumentValue
  TypeRestriction
  AssignmentTarget
  Operator
  BlockParameter
end

struct HirSource
  getter syntax : SyntaxPtr
  getter role : SourceRole
  getter index : Int32?
end

struct HirHit
  getter body : BodyId
  getter expr : ExprId?
  getter binding : BindingId?
  getter range : TextRange
  getter role : SourceRole
  getter index : Int32?
end
```

Examples:

```text
cursor on "method"
→ call ExprId, role=Name

cursor on "first"
→ first argument ExprId, role=Whole
→ call ExprId, role=Argument, index=0

cursor on "name:"
→ call ExprId, role=NamedArgumentName, index=0

cursor on "second"
→ second expression ExprId, role=Whole
→ call ExprId, role=NamedArgumentValue, index=0
```

These distinctions support signature help, rename, named-argument completion,
and goto definition.

## 11. Return a semantic hit stack

One cursor position can correspond to several semantic objects.

For:

```crystal
service.process(value)
```

a hit stack can contain:

```text
LocalRef(value)
Call(service.process)
expression statement
method body
method declaration
class declaration
```

Represent the stack explicitly:

```crystal
enum SemanticHitKind
  Binding
  Expression
  Statement
  Body
  Declaration
end

struct SemanticHit
  getter kind : SemanticHitKind
  getter range : TextRange
  getter id : SemanticId
  getter role : SourceRole
end

struct SemanticContext
  getter file : FileId
  getter offset : UInt32
  getter syntax_path : Array(SyntaxPtr)
  getter hits : Array(SemanticHit)
end
```

Sort hits from narrowest to broadest.

Feature selection:

| Feature | Preferred hit |
|---|---|
| Hover | expression or binding |
| Goto definition | reference, binding, or call name |
| Completion | containing expression, body, and scope |
| Signature help | nearest enclosing call |
| Rename | exact binding or resolved declaration |
| Document symbols | declaration |

## 12. HIR lookup algorithm

Use this order:

1. Convert the LSP position to a byte offset.
2. Get the Tree-sitter leaf and ancestor path.
3. Find the smallest containing item and body.
4. Lower the body if needed.
5. Look for exact `SyntaxPtr` mappings from narrowest syntax node upward.
6. Query the HIR span index at the offset.
7. Merge and rank the hits.
8. Map the chosen HIR object to inference or resolution data.

Pseudocode:

```crystal
def semantic_context_at(
  snapshot : Snapshot,
  file : FileId,
  lsp_position : LSP::Position,
  bias : CursorBias,
) : SemanticContext
  document = snapshot.document(file)
  offset = document.line_index.byte_offset(lsp_position)
  syntax_nodes = syntax_path_at(
    document.tree.root_node,
    offset,
    document.text.bytesize.to_u32,
    bias,
  )
  syntax_ptrs = syntax_nodes.map { |node| SyntaxPtr.from(file, node) }

  file_map = snapshot.database.file_semantic_map(file)
  item = file_map.items.smallest_containing(offset)
  body_id = file_map.bodies.smallest_containing(offset)

  hits = [] of SemanticHit

  if body_id
    lowered = snapshot.database.lower_body(body_id)

    syntax_ptrs.each do |syntax_ptr|
      hits.concat(lowered.source_map.hits_for(syntax_ptr))
    end

    hits.concat(lowered.source_map.spans.containing(offset))
  end

  hits << SemanticHit.declaration(item) if item

  SemanticContext.new(
    file: file,
    offset: offset,
    syntax_path: syntax_ptrs,
    hits: rank_hits(hits, offset),
  )
end
```

Deduplicate hits by semantic ID and role.

## 13. Span index

Build range indexes during item collection and body lowering. Do not scan every
HIR node on each request.

A simple initial implementation:

```crystal
struct SpanEntry(T)
  getter range : TextRange
  getter value : T
end

class SpanIndex(T)
  def initialize(@entries : Array(SpanEntry(T)))
    @entries.sort_by! { |entry| {entry.range.start_byte, entry.range.size} }
  end

  def containing(offset : UInt32) : Array(T)
    @entries
      .select { |entry| entry.range.contains?(offset) }
      .sort_by { |entry| entry.range.size }
      .map(&.value)
  end

  def smallest_containing(offset : UInt32) : T?
    containing(offset).first?
  end
end
```

A linear scan is acceptable for the first body-level implementation. Replace it
with binary-search-based intervals or an interval tree only after profiling.

## 14. Token boundaries and tie-breaking

Several ranges can have the same size or share an endpoint. Rank hits using:

1. exact token or source-role match;
2. range strictly containing the cursor;
3. smaller range;
4. expression or binding before statement;
5. body before declaration;
6. left or right bias selected by the feature.

Treat most semantic ranges as half-open:

```text
[start_byte, end_byte)
```

Then define a separate cursor containment rule:

```crystal
def contains_cursor?(range : TextRange, offset : UInt32, bias : CursorBias)
```

This avoids making every range include its end and accidentally overlapping
adjacent tokens.

## 15. Program-point lookup for CFA

Flow-sensitive completion needs the environment at the cursor, not only an
`ExprId`.

Map HIR expressions and operation boundaries to CFG points:

```crystal
struct ProgramPoint
  getter block : BlockId
  getter operation_index : Int32
  getter phase : ProgramPointPhase
end

enum ProgramPointPhase
  Before
  After
end

struct CfgSourceMap
  getter expr_entry : Hash(ExprId, ProgramPoint)
  getter expr_exit : Hash(ExprId, ProgramPoint)
  getter spans : SpanIndex(ProgramPoint)
end
```

Example:

```crystal
value = foo.ba|
```

The cursor inside the assignment value should use the environment before the
assignment to `value`.

For:

```crystal
value = foo
value.|
```

the cursor should use the environment after the assignment.

The semantic role and `Before`/`After` phase make that distinction explicit.

## 16. Feature pipelines

### Hover

```text
position
→ semantic hit
→ ExprId or BindingId
→ infer_body(BodyId)
→ type_of(ExprId) or type_of(BindingId)
```

### Local goto definition

```text
position
→ LocalRef ExprId
→ BindingId
→ binding source pointer
→ LSP location
```

### Method goto definition

```text
position on call name
→ Call ExprId, role=Name
→ resolve_call(Call ExprId)
→ candidate DefIds
→ declaration source locations
```

### Completion

```text
position
→ syntax completion context
→ containing body and expression
→ CFG program point
→ flow environment
→ receiver TypeSet
→ methods_of(receiver types)
```

### Signature help

```text
position
→ nearest enclosing Call ExprId
→ argument source role and index
→ resolve_call(Call ExprId)
→ viable signatures and active parameter
```

### Rename

```text
position
→ exact BindingId or DefId
→ indexed semantic references
→ versioned workspace edit
```

Do not use textual token matching as the primary rename identity.

## 17. Incomplete syntax

Tree-sitter can return an error or missing node for:

```crystal
service.
```

Use two fallback paths.

### Containing semantic context

Walk from the error node to mapped parent syntax:

```text
ERROR node
→ parent expression
→ containing body
→ current scope
→ current flow environment
```

This is sufficient for many completion requests.

### Ephemeral completion HIR

When the incomplete construct has no persistent HIR representation, create a
request-local synthetic expression:

```text
Call
├── receiver: LocalRef(service)
└── name: Missing
```

Another option is a scratch source:

```crystal
service.__opal_completion__
```

Parse and lower the scratch expression without publishing it to the persistent
body cache.

## 18. Synthetic and macro-generated HIR

Synthetic declarations or expressions need source origins:

```crystal
struct SyntheticOrigin
  getter invocation : SyntaxPtr
  getter definition : SyntaxPtr?
end
```

For a generated getter:

```crystal
getter name : String
```

the synthetic `name` method should navigate to the `getter` invocation. Hover
can also link to the macro definition if available.

Synthetic HIR might have no exact syntax pointer. Include it in semantic lookup
through the invocation range and mark its role as generated.

## 19. Snapshot and revision safety

HIR IDs belong to one semantic snapshot.

After an edit:

```text
old snapshot: BodyId 7, ExprId 12 = one expression
new snapshot: BodyId 7, ExprId 12 = possibly another expression
```

Do not retain `ExprId` or `BindingId` across requests without the owning
snapshot or body revision.

Longer-lived identities should use:

- `DefId` for stable declarations when interned appropriately;
- `FileId + SyntaxPtr` for syntax anchors;
- `BodyId + body revision` for cached body data.

One request must perform syntax lookup, HIR lookup, inference, and source
conversion against the same immutable snapshot.

## 20. Cache ownership and invalidation

Suggested cache boundaries:

```text
parse(FileId, file revision)
    → Tree-sitter tree

collect_items(FileId, syntax revision)
    → FileSemanticMap

lower_body(BodyId, body syntax revision)
    → Body + BodySourceMap + HIR SpanIndex

body_cfg(BodyId, HIR revision)
    → CFG + CfgSourceMap

infer_body(BodyId, CFG and dependency revisions)
    → InferenceResult
```

An edit invalidates only intersecting bodies unless the changed syntax alters
item structure, method signatures, namespace relationships, or project
requires.

## 21. Suggested initial types

```crystal
enum CursorBias
  Left
  Right
  Exact
end

enum SourceRole
  Whole
  Name
  Receiver
  Argument
  NamedArgumentName
  NamedArgumentValue
  TypeRestriction
  AssignmentTarget
  Operator
  BlockParameter
end

enum SemanticHitKind
  Binding
  Expression
  Statement
  Body
  Declaration
end

struct SemanticContext
  getter file : FileId
  getter offset : UInt32
  getter syntax_path : Array(SyntaxPtr)
  getter hits : Array(SemanticHit)
end
```

Add typed accessors:

```crystal
context.expression?
context.binding?
context.call?
context.call_name?
context.containing_body?
context.containing_declaration?
context.program_point?
```

## 22. Initial implementation sequence

1. Implement UTF-16 position to byte-offset conversion.
2. Add `CursorBias` and Tree-sitter leaf lookup.
3. Return the leaf-to-root syntax path.
4. Add file-level item and body span indexes.
5. Lower one method body and create `SyntaxPtr ↔ ExprId` maps.
6. Add a body-level HIR span index.
7. Add semantic source roles for call names, receivers, arguments, assignment
   targets, and type restrictions.
8. Return a narrow-to-broad semantic hit stack.
9. Implement local goto definition through `BindingId`.
10. Add CFG program points when flow-sensitive completion starts.

Local goto definition is the best first integration test because it exercises:

- LSP position conversion;
- Tree-sitter lookup;
- body selection;
- HIR lowering;
- lexical binding resolution;
- reverse source mapping;
- LSP location conversion.

It does not require type inference.

## 23. Test cases

### UTF-16 and byte offsets

```crystal
message = "✅"
message.upcase
```

Verify positions after the emoji.

### Boundary bias

Test the cursor:

```text
before token
inside token
after token
on `.`
on `,`
on `)`
at end of file
```

### Semantic roles

```crystal
receiver.method(first, name: second)
```

Verify receiver, method name, positional argument, named label, and named value
hits.

### Shadowing

```crystal
value = 1

items.each do |value|
  value.to_s
end

value.abs
```

Verify each local reference maps to the correct `BindingId`.

### Normalized HIR

```crystal
unless value.nil?
  value.upcase
end
```

Verify the original syntax maps to the normalized `Not` and `If` expressions.

### Incomplete calls

```crystal
service.
foo(
foo(first,
```

Verify the containing body, scope, receiver, call, and active argument remain
discoverable.

### Flow points

```crystal
value = foo
value.
```

Verify completion uses the environment after the assignment.

```crystal
value = foo.ba
```

Verify a cursor inside `foo.ba` uses the environment before assignment.

### Snapshot revisions

Change source so expression IDs are reused. Verify a request using the old
snapshot cannot read semantic data from the new snapshot.

## 24. Design rules

1. Convert LSP positions to byte offsets once at the protocol boundary.
2. Make cursor bias explicit.
3. Use Tree-sitter for spatial syntax lookup.
4. Use source maps and span indexes for HIR lookup.
5. Preserve a leaf-to-root syntax path.
6. Return multiple semantic hits instead of forcing one universal node.
7. Record source roles for important subranges.
8. Keep HIR IDs scoped to their body revision and snapshot.
9. Build range indexes during lowering, not during each request.
10. Resolve semantic meaning after locating the HIR object.
11. Preserve surrounding context when syntax is incomplete.
12. Keep lookup logic shared across all LSP features.

## 25. Summary

Tree-sitter provides:

```text
byte range → CST node
```

Opal must provide:

```text
CST node or source range → semantic hit stack
```

The full request path is:

```text
DocumentURI + LSP position
→ FileId + byte offset
→ Tree-sitter leaf and ancestors
→ containing item and body
→ BodySourceMap and SpanIndex
→ ExprId / BindingId / DefId
→ CFG ProgramPoint when needed
→ inference or resolution result
→ LSP response
```

HIR should not duplicate Tree-sitter's `descendant_for_point_range`. HIR should
expose range-indexed source maps because its structure follows program meaning,
not source geometry.

