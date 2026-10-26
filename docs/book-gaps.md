# Book gaps

Differences between clear-ls inference and the
[Crystal 1.22 syntax and semantics book](https://github.com/crystal-lang/crystal-book/tree/release/1.22/docs/syntax_and_semantics),
found by running the book's examples through both the compiler and
clear-ls. Phase 8 in the [roadmap](roadmap.md) works through this list.

## Goal

clear-ls does not try to reproduce the compiler exactly. Its inference is
best-effort and DX-first, and `crystal tool` results (diagnostics, facts,
`tool context`) stay the source of truth where precision matters. In this
phase:

- **Wrong** results are fixed: a known type that the compiler disagrees
  with in a way that misleads the user (completion offers methods that
  don't exist, hover shows a type that the code can't have).
- **Unknown** results are filled in where a cheap, local rule exists.
- **Deviations** are allowed where our answer is more useful in an editor
  and is still sound. They are recorded below and marked in the fixtures.

## Harness

```sh
make bin/probes/type_marks
tools/book_diff.py [FILE...]
```

`tools/fixtures/book/src/*.cr` are the book's examples with `__t(expr)`
markers. The compiler prints `typeof(expr)` for every marker through the
macro in `h.cr`. The `type_marks` probe prints clear-ls's type for each
marker in the compiler's spelling. `book_diff.py` prints the lines where
the two disagree. A trailing `# cls: TYPE  reason` on a marker line
records an accepted deviation.

Baseline (Phase 7 end, Crystal 1.22.0): 191 of 290 markers match, 1 is an
accepted deviation. Of the 98 mismatches, 25 are wrong results and the
rest are unknown or wider than the compiler's type.

Progress (book fixtures; the second number counts the fixtures added
during this phase: `autocast.cr`, `enums.cr`, `primitives.cr`,
`loops.cr`, `procs.cr`, `splats.cr`, `closures.cr`, `ivars.cr`, `narrowing.cr`;
their accepted deviations are counted as matches):

| After | Match | Wrong left |
|---|---|---|
| baseline | 191/290 | 25 |
| step 1 (A, B) | 202/290 + 19/19 | 21 |
| step 2 (C) | 211/290 + 46/47 | 19 |
| step 3 (D) | 233/290 + 103/104 | 10 |
| step 4 (E) | 238/290 + 118/121 | 7 |
| step 5 (F) | 246/290 + 150/150 | 5 |
| step 6 (G) | 250/290 + 174/174 | 2 |
| step 7 (H, I) | 256/290 + 195/195 | 0 |
| step 8 (J, K) | 267/290 + 228/228 | 0 |

Entries marked **fixed (step N)** stay in the tables as a record.

## Categories

IDs are used by the roadmap steps. *Wrong* = known but incorrect;
*unknown* = clear-ls prints `?`; *wider* = sound but less precise.

### A. Literals

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| A1 | `2147483648` | `Int64` | `Int32` | **fixed (step 1)**; was wrong: suffix-less literals are Int32 only when they fit, else Int64 (else UInt64) |
| A2 | `..2` | `Range(Nil, Int32)` | `Range(Int32, Nil)` | **fixed (step 1)**; was wrong: begin-less range puts the end in `B` |
| A3 | `__LINE__`, `__FILE__`, `__DIR__` | `Int32`, `String` | `?` | **fixed (step 1)**; was unknown (`pseudo_constant`) |

### B. Autocasting and overload ranking

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| B1 | `over(1.5)` with `over(x : Int32)`, `over(x)` | `Char` | `Int32` | **fixed (step 1)**; was wrong: float literals never autocast to integers |
| B2 | `cnt = 1; cnt += 2.0` | `Float64` | `Int32` | **fixed (step 1)**; was wrong: same cause, and op-assign ignored the number primitives |
| B3 | `ov(1)` with `ov(x : Int32)`, `ov(x : Float64)` | `Int32` | `Int32 \| String` | **fixed (step 1)**; was wider: an exact match beats an autocast match |
| B4 | `i ** 2` | `Int32` | `Float64 \| Int32` | **fixed (step 1)**; was wider: same cause |

Rules implemented in step 1 (autocasting.md, each case checked against
Crystal 1.22 in `fixtures/book/src/autocast.cr`):

- Integer literals cast to any integer or float type, float literals only
  to float types, `:sym` literals to enums. The literal's value is not
  range-checked (an out-of-range literal is a compile error, which the
  compiler reports).
- Other number values cast only without precision loss: to a wider
  integer of the same signedness, unsigned to a wider signed integer,
  integers narrower than the float's mantissa to that float (Int16 to
  Float32, Int32 to Float64), Float32 to Float64.
- Overloads that fit without a cast win over those that need one, and an
  unrestricted parameter is an exact fit. Several cast-only fits stay
  ambiguous (the compiler reports an error there).
- Summaries bind a restricted parameter to the argument's type only when
  it fits without a cast (`x : Int64` called with an Int32 is an Int64
  inside).

### C. Enums

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| C1 | `Big::A` (`enum Big : UInt8; A = 1`), `C::E::X` (lib enum) | `Big`, `C::E` | `Int32` | **fixed (step 2)**; was wrong: members were typed from their value text like constants |
| C2 | `Color::Red` (no value), `Big::B` | `Color` | `?` | **fixed (step 2)**; was unknown |
| C3 | `Color::Red.value`, `Big::A.value` | `Int32`, `UInt8` | `?` | **fixed (step 2)**; was unknown: `value` is the base type |
| C4 | `Perm::Read \| Perm::Write`, `.read?` on `@[Flags]` | `Perm`, `Bool` | `?` | **fixed (step 2)**: members typed as the enum let `\|` and predicates resolve; `None`/`All` of `@[Flags]` enums are synthesised |

### D. Primitives and built-ins

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| D1 | `Dog.new.class`, `pet.class`, `Person.new.class` | `Dog.class` | `Nil` | **fixed (step 3)**; was wrong: empty `@[Primitive]` bodies summarised as `Nil`. Primitives without a return type are typed in `primitive_return` (`class`, `pointer_malloc`, `pointer_new`) or unknown |
| D2 | `Pointer(Int32).malloc(1)`, `IntP.malloc(1)` | `Pointer(Int32)` | `Nil` | **fixed (step 3)**; `IntP` also needed aliases to generic instances (`alias Bytes = Slice(UInt8)`) to keep their args |
| D3 | `i == 1` | `Bool` | `?` | **fixed (step 3)**: comparison operators whose resolved defs have no type are Bool |
| D4 | `i / 2` | `Float64` | `?` | **fixed (step 3)**: `/`, `//`, `%`, `<=>` number rules (checked against the compiler) |
| D5 | `pointerof(x)`, `sizeof`/`instance_sizeof`/`alignof`/`offsetof` | `Pointer(Int32)`, `Int32` | `?` | **fixed (step 3)**: lowered; `obj.@x` reads the ivar |
| D6 | `x.unsafe_as(Float32)`, `Pointer(Int32).null`, `Person.name`, `Int32.class` | `Float32`, `Pointer(Int32)`, `String`, `Class` | `?` | **fixed (step 3)**: `T.class` restrictions unify with type arguments; `def self.x` bodies run on the metaclass; types answer `Class` methods |
| D7 | `$~`, `$1` after `=~` | `Regex::MatchData`, `String` | `?` | **fixed (step 3)**; `$1?`/`$~?` are nilable |
| D8 | `select … end`, `spawn { }` | `Int32?`, `Fiber` | `?` | `select` **fixed (step 3)** (a `case` without subject whose actions don't narrow). `spawn` is an accepted deviation: the stdlib defines it inside `{% begin %}` with a macro in its parameter list, which the item tree does not see |
| D9 | `1.try { … }`, `nil.try { 1 }` | `String`, `Nil` | `String?`, `Int32?` | **fixed (step 3)**: per receiver member |

### O. Found while fixing (not in the book)

Older inference bugs that the book fixes exposed, fixed in the step that
hit them:

| ID | Problem | Fix (step) |
|---|---|---|
| O1 | Summaries of `def self.x` bodies ran on the instance: `new`, sibling class methods unknown | metaclass `self` in class-method bodies (3) |
| O2 | An abstract def and its implementation in an includer both stayed viable for unknown arguments, so the abstract one's missing return made the call unknown (`Array#unsafe_fetch(i)`) | an override with the same restrictions hides the overridden def (3) |
| O3 | `Tuple(A, B)` written nominally (`Array(Tuple(Int32, Int32, P))`) did not index like `{A, B}` | parsed as the structural tuple (3) |
| O4 | Over the 8-shape cap a summary lost the caller's block value; `yield` became Pending and `if v; yield v; end` summarised to `Nil` (and the results depended on which defs ran first) | cap 16; over it, return summaries keep the block value and literal defaults, yield summaries keep the argument types (3) |
| O5 | Bodies whose `return` sits inside `{% %}` (`Range#bsearch`) summarised from the remaining code | such bodies return unknown (3) |
| O7 | Bodies with a `return` inside `{% if flag? %}` summarised to unknown since O5, losing e.g. `Crystal::System.effective_cpu_count : Int32` | only `{% for %}`/`{{ }}` returns make a summary unknown; flag-conditional ones are platform variants (7) |
| O6 | `alias A = G(T)` resolved to bare `G`, losing `T` (`Bytes` was `Slice`) | the parser follows the alias's target text (3) |

### E. Loops, `break`, and `next`

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| E1 | `x = while …; break "four"; break 3; end` | `Int32 \| String \| Nil` | `Nil` | **fixed (step 4)**; was wrong: `break` values were dropped |
| E2 | `while true; break 1; end` | `Int32` | `Nil` | **fixed (step 4)**: only `while true` (the compiler does not special-case `until false`) |
| E3 | `loop { break 1 }`, `[1].each { break "s" }` | `Int32`, `String?` | `Nil` | **fixed (step 4)**; a block's `break` value joins the call's type |

### F. Procs and blocks

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| F1 | `-> : Int32 \| String { 1 }`, `->(x) : Nil { … }` | declared return | body type | **fixed (step 5)**; was wrong: the proc's return annotation was ignored |
| F2 | `[1].map(&pr)` | `Array(Int32)` | `Array(Proc(Int32, Int32))` | **fixed (step 5)**; was wrong: a passed proc's value is its return type, not the proc |
| F3 | `->one`, `->plus_one(Int32)`, `->str.count(Char)` | `Proc(…)` | `?` | **fixed (step 5)**: the overload the param types select |
| F4 | `cap2 { … }` with `&block : Int32 -> _` | `Proc(Int32, Float64)` | `Proc(Int32, ?)` | **fixed (step 5)**: `_` takes the block's value; a bare `&block` is `Proc(Nil)` |
| F5 | `with "str" yield` → `upcase` in the block | `String` | `?` | **fixed (step 5)**: summaries record the `with` receiver; calls and completion in the block use it |

### G. Splats and tuples

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| G1 | `def s(*xs : Int32)`, `s(1, 2)` | `Tuple(Int32, Int32)` | `Tuple(Int32)` | **fixed (step 6)**: the tuple of the bound arguments |
| G2 | `{1, *t}` | `Tuple(Int32, String, Char)` | `Tuple(Int32, ?, String, Char)` | **fixed (step 6)**: the grammar splits `*x` into ERROR + operand; lowering rejoins it. A literal operand (`{1, *{…}}`) mis-parses and stays unknown (accepted) |
| G3 | `q, *rest = 1, "a", 'c'` | `rest : Tuple(String, Char)` | `String` | **fixed (step 6)**; `*rest` from an array is an `Array` |
| G4 | `def sum(*elements)`, `def f(**opts)` | `Tuple(Int32, …)`, `NamedTuple(y: …)` | `Tuple`, `NamedTuple` | **fixed (step 6)** for calls; inside the def (no call) they stay `Tuple`/`NamedTuple` (accepted: the compiler types each instantiation) |
| G5 | `add(*tup)`, `add(**nt)` | `Int32` | `?` | **fixed (step 6)**: tuple / named-tuple types expand into arguments |
| G6 | `[1, *coll]`, `Set{1, *coll}` | `Array(Float64 \| Int32)` | `Array(?)` | **fixed (step 6)**: element type of the splatted enumerable |

### H. Closures

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| H1 | `x = 1; -> { x = "s" }; x = 'a'; x` and captured blocks (`&block`) | `Char \| Int32 \| String` | `Char` | **fixed (step 7)**: locals used in a proc literal or a captured block (`&block` without `yield`) take the join of all their assignments and are not narrowed by truthiness (`is_a?`/`nil?`/`case` still narrow, as in the compiler) |

### I. Methods: redefinition, `super`, generics

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| I1 | second `def m` calling `previous_def` | `Float64` | `Int32` | **fixed (step 7)**: a later def with the same restriction key (defaulted trailing params ignored, as in the compiler) hides the earlier one; `previous_def` calls it |
| I2 | `def foo; super.to_s; end` | `String` | `?` | **fixed (step 7)**: bare `super` forwards the def's arguments |
| I3 | `MyBox.new(1)`, `.value` | `MyBox(Int32)`, `Int32` | `MyBox`, `?` | **fixed (step 7)**: unified from the `initialize` restrictions |
| I4 | `def self.create; new("a"); end` | `Person` | `?` | **fixed (step 3, O1)** |

### J. Instance and class variables

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| J1 | `@age = 0`, `@addr = Address.new`, `@vals = Array(Int32).new` | literal / `T.new` type | `?` | **fixed (step 8)**: `Origin::Assigned` ivar items from def bodies; literals include collections and `c ? a : b` of literals |
| J2 | `@nick = nick` with `nick = "x"`, `@p3 = obj` with `obj : Int64` | param restriction / default | `?` | **fixed (step 8)** |
| J3 | `@x = Address.make`, `@x = LibX.compute`, `LibX.get(out @x)` | class method / fun / `out` type | `?` | `Type.m` with a declared return or ending in `new` **fixed (step 8)**; lib funs and `out` are left to compiler facts (decision 5, accepted) |
| J4 | an ivar assigned outside every `initialize` | `T \| Nil` | — | **fixed (step 8)**: Nil unless every `initialize` assigns it; class vars assigned in defs are nilable |

Compiler facts already fill these after a successful check and take
precedence (assigned items are replaced by facts). This item covers code
that hasn't been checked or saved yet. Note: the compiler rejects an ivar
assigned only in one branch of `initialize` (it doesn't make it nilable).

### K. Narrowing

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| K1 | `if y.responds_to?(:upcase)` | `String` | `Int32 \| String` | **fixed (step 8)**: members with / without the method |
| K2 | `case {p1, p2}` / `when {String, Char}` | `String`, `Char` | unnarrowed | **fixed (step 8)**: per element on a match; `_` skips |
| K3 | `case num = expr` / `when Int32` | `Int32` | `Int32?` | **fixed (step 8)** |

### L. C bindings

| ID | Example | Compiler | clear-ls | Kind |
|---|---|---|---|---|
| L1 | `C::S.new.a`, `C::U.new.f` (lib struct/union fields) | field type | `?` | unknown |
| L2 | `C.strlen("a")` (`fun … : C::Size`), `C.errno` (`$errno : Int32`) | `UInt64`, `Int32` | `?` | unknown |

### M. Union shape

These are not wrong, just shaped differently from the compiler's types.
How each is handled: [Decisions](#decisions).

| ID | Example | Compiler | clear-ls |
|---|---|---|---|
| M1 | `cond ? Bar.new : Baz.new` (both `< Foo`), `rescue ex : A \| B` | `Foo+` (printed `Foo`), `Exception+` | `Bar \| Baz`, `A \| B` |
| M2 | `cond ? {1, "a"} : {true, nil}`, same-key named tuples | `Tuple(Bool \| Int32, String \| Nil)` | union of two tuples |
| M3 | `nn : Int32 \| Float64 = 1`, `n : Int32? = nil` | `Int32`, `Nil` (assigned type) | declared type |
| M4 | `def f : Int32 \| String` whose body returns `1` | `Int32` | `Int32 \| String` |
| M5 | `Int32 \| String`, `Int32?` used as values | `(Int32 \| String).class` | `?` |

### N. Out of scope for this phase

These came up in the comparison but are not about inference. They stay in
[architecture.md](architecture.md#known-limitations) and later phases:

- `protected` methods are offered in completion outside their type;
  `:ditto:` and `:inherit:` doc directives are not handled.
- `method_missing`, `forward_missing_to`, `delegate` (only compiler facts).
- Locals and fresh variables inside macro bodies.
- Iterator chain generics (`each_with_index.map` gives
  `MapIterator(?, Int32, ?)`).

## Accepted deviations

| Where | clear-ls | Compiler | Why |
|---|---|---|---|
| `flow.cr:59` | `Int32 \| String` once | `Int32`, then `Int32 \| String` | The compiler prints once per loop fixed-point step; clear-ls shows the joined fixed point |
| `loops.cr` `forever` | `NoReturn` | not typed | A def whose body is `while true` without `break`: the compiler doesn't instantiate code after it; clear-ls reports `NoReturn` |
| `splats.cr` inside `sum`/`opts` | `Tuple`, `NamedTuple` | one type per call | A def body analysed on its own has no call; hover inside it shows the open shape (call sites get the exact tuple) |
| `literals.cr:62` | `?` | `Tuple(Int32, String, Char)` | `{1, *{"a", 'b'}}`: the grammar mis-parses a splatted literal (tree-sitter-grammar-notes) |
| `ivars.cr` `@lib_age`, `@out_age` | `?` / from facts | `Int32` | Rules 6–7 (lib fun results, `out`) come from compiler facts only (decision 5) |
| `ivars.cr` `Gen#x` | `T` | `Int32` | Generic def analysed on its own; `Gen.new(1).x` at the call site is `Int32` |
| `primitives.cr:85` | `spawn { }` unknown | `Fiber` | `def spawn` is inside `{% begin %}` with a macro in its parameter list; macro bodies are not modelled (N) |

## Decisions

Agreed before step 1. Steps 7 and 8 implement them.

1. **Virtual types (M1).** Keep exact unions (`Bar | Baz`) for hover and
   narrowing. Method lookup and completion fall back to the nearest common
   ancestor (not `Reference`/`Value`/`Int`/`Float`) when a method is not
   on every member; an abstract parent then resolves through its
   subclasses' implementations. `rescue ex : A | B` stays `A | B`.
2. **Tuple unions (M2).** Keep the union of tuples. Indexing by a literal
   and destructuring take the per-position union.
3. **Declared locals (M3).** Hover shows the flow type (`Int32`) and the
   declared type as a note. Later assignments are still allowed anywhere
   within the declared type.
4. **Restricted returns (M4).** Use the declared return type; it is the
   method's contract, and narrowing it would make callers look wrong
   whenever the body changes.
5. **Ivar rules (J).** Implement the book's rules 1–5 in clear-ls
   (literals, `T.new`, restricted or defaulted params, plus `Nil` when not
   set in every `initialize`), so ivars are typed before the first check
   and in unsaved buffers. Compiler facts win when present. Rules 6–7
   (lib funs, `out`) come from facts only.
6. **Types as values (M5).** Type `Int32 | String` / `Int32?` in
   expression position as metaclasses only if the grammar gives them a
   type node; if they parse as calls to `|`, leave them unknown.
