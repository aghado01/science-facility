The interesting discovery is that `ast-grep/` is not Nushell’s AST implementation. It is a tree-sitter-based lint suite that happens to expose an unfinished, fairly ambitious span refactor inside Nushell.

I inspected the clean `main` checkout at `4d9d0c077`, workspace version `0.115.2`.

## What the ast-grep rules mean

There are two different notions of “span” visible there:

- ast-grep’s snapshot `start`/`end` values are ranges for tree-sitter matches inside Rust source.
- The matched Rust code refers to Nushell’s own `nu_protocol::Span`.

The rules themselves are maintenance policy:

- [internal_span.yml](D:/aghado01/packages/nu/nushell/ast-grep/rules/internal_span.yml:3) prohibits destructuring `Value::internal_span`; callers should use `Value::span()`. That field belongs to runtime values and is explicitly being refactored away, as seen in [value/mod.rs](D:/aghado01/packages/nu/nushell/crates/nu-protocol/src/value/mod.rs:79).
- [span-unknown.yml](D:/aghado01/packages/nu/nushell/ast-grep/rules/span-unknown.yml:3) warns on `Span::unknown()`, encouraging real source provenance.

`internal_span` is an error-level regression guard. `span-unknown` is still aspirational: this checkout contains 166 textual uses across 68 crate files. I also found no in-repository CI invocation of `ast-grep scan`; the configuration, rules, tests, and snapshots exist, but invocation appears to be editor/manual tooling.

## The actual parsing mechanics

Nushell is unusually span-first:

```text
CachedFile { name, bytes, covered_span }
                    │
                    ▼
       lexer → Token { coarse kind, Span }
                    │
                    ▼
       lite parser → commands containing Vec<Span>
                    │
                    ▼
 Expression { Expr, Span, SpanId, Type }
          │              │
          ├─ diagnostics/miette
          ├─ flattening → highlighting/completions
          ├─ lowering → IR + parallel instruction spans
          └─ evaluation → Values carrying source spans
```

The central type is only:

```rust
pub struct Span {
    pub start: usize,
    pub end: usize,
}
```

But its coordinates are global half-open byte offsets across every source cached by the engine, not file-local line/column coordinates. See [span.rs](D:/aghado01/packages/nu/nushell/crates/nu-protocol/src/span.rs:138).

Each cached source owns a disjoint global range through [CachedFile](D:/aghado01/packages/nu/nushell/crates/nu-protocol/src/engine/cached_file.rs:4). Adding a source assigns it `[previous_end, previous_end + byte_length)`. Extracting text finds the containing file, subtracts its base, and slices the stored `Arc<[u8]>`; [StateWorkingSet::add_file/get_span_contents](D:/aghado01/packages/nu/nushell/crates/nu-protocol/src/engine/state_working_set.rs:334) shows the complete mechanism.

A few consequences:

- Coordinates count raw bytes, not Unicode scalars or UTF-16 code units.
- Filename and revision identity are not inside `Span`.
- Identical filename-and-content pairs are reused; changed content gets a new global range.
- Line and column are derived later when diagnostics are rendered.
- File-local reporting is produced by subtracting `covered_span.start`.
- A span crossing two files cannot resolve to source.
- Since file ranges abut, a zero-width span at a boundary can satisfy containment for both adjacent files; iteration order decides which one supplies context.

The lexer is also quite coarse. [TokenContents](D:/aghado01/packages/nu/nushell/crates/nu-parser/src/lex.rs:9) distinguishes pipes, comments, redirections, EOL, and a general `Item`. Tokens retain spans rather than copied strings. The [lite parser](D:/aghado01/packages/nu/nushell/crates/nu-parser/src/lite_parser.rs:62) then constructs pipeline structure almost entirely from `Vec<Span>` and asks the working set for the corresponding bytes when it needs meaning.

That is the part most spiritually adjacent to Doccer: source geometry is the durable carrier, while successive stages derive interpretations over it.

The full parser then becomes semantic very quickly:

- It resolves declarations and variables to `DeclId`/`VarId`.
- Nested blocks are stored in engine arenas and referenced by `BlockId`.
- `Expression` carries an inferred `Type`.
- Definitions are predeclared before pipeline parsing.
- Type checking happens before `parse_block` returns.
- Errors accumulate in `StateWorkingSet`, while `Expr::Garbage` preserves a damaged region so parsing and highlighting can continue.

See [Expr](D:/aghado01/packages/nu/nushell/crates/nu-protocol/src/ast/expr.rs:12), [Expression](D:/aghado01/packages/nu/nushell/crates/nu-protocol/src/ast/expression.rs:11), and [parse_block](D:/aghado01/packages/nu/nushell/crates/nu-parser/src/parse_pipelines.rs:129).

It is therefore a semantic AST, not a lossless concrete syntax tree. Ordinary whitespace is skipped, comments are mainly converted into descriptions/doccomments, and literals become decoded Rust values. The original source remains recoverable because it is cached externally, but the AST alone cannot reproduce it.

## The unfinished `SpanId` design

Every parsed `Expression` currently carries both:

```rust
pub span: Span,
pub span_id: SpanId,
```

`Expression::new` appends the span to `StateWorkingSet.delta.spans` and stores its index. Merging the delta extends the permanent engine span table. This is an indexed arena, not true deduplicating interning.

The original design proposed eventually replacing spans with IDs and then turning those IDs into node IDs for a new parser. The staged plan is recorded in [Nushell issue #12963](https://github.com/nushell/nushell/issues/12963). The current checkout is still distinctly hybrid: raw spans remain widespread, `Call` still carries direct spans, and there is no `NodeId` implementation.

The most revealing use is external aliases:

- The parser clones an external-command expression from the alias definition.
- It overwrites `head.span` with the alias occurrence at the call site.
- It leaves `head.span_id` pointing at the original command text.
- The flattening stage uses both: one to determine what command is being highlighted, the other to determine where the highlight belongs.

That is explicit in [parse_calls.rs](D:/aghado01/packages/nu/nushell/crates/nu-parser/src/parse_calls.rs:1604) and [flatten.rs](D:/aghado01/packages/nu/nushell/crates/nu-parser/src/flatten.rs:365). A historical attempt to extend the `SpanId` refactor into `Call` was reverted because it broke alias highlighting and caused completion panics.

This exposes the underlying modeling problem: “where this occurrence is written” and “where this semantic object originated” are two different relations. One span-shaped concept was being asked to represent both.

There are other transitional sharp edges:

- `Span::unknown()` is literally `[0,0)`, making it indistinguishable from `Span::point(0)`.
- `contains_span` contains a special `end != 0` check to stop that sentinel resolving as source.
- `Span::test_data()` uses another magic coordinate.
- `Span::new` checks `end >= start` only with `debug_assert!`, while both fields remain public.
- `Block` deliberately uses `Option<Span>` to avoid another sentinel.
- `Span::concat` and `merge_many` produce `unknown()` for an empty collection.

The warning rule is therefore pointing at a genuine provenance and type-model debt, not merely stylistic tidiness.

A live `ast '1 + 2' --json` probe using the installed Nu 0.114.1 showed the same design concretely: large session-global offsets, numeric span IDs, nested overlapping expression spans, and an IR block with a parallel span for every instruction. Flattened AST output rebases those global coordinates back to `0..input_length`. The implementation lives in [debug/ast.rs](D:/aghado01/packages/nu/nushell/crates/nu-command/src/debug/ast.rs:155) and [IrBlock](D:/aghado01/packages/nu/nushell/crates/nu-protocol/src/ir/mod.rs:36).

## What this suggests for Doccer

Doccer currently has stronger coordinate and lineage foundations than Nushell:

| Concern | Nushell | Doccer |
|---|---|---|
| Coordinate identity | Ambient global engine arena | Explicit `TextMaster` snapshot identity |
| Unit | Raw bytes | Declared UTF-16 code units |
| Bounds | Public fields; mostly caller discipline | Master validation and scalar-boundary checks |
| Slices | Global offset subtraction | Explicit, reversible `TextSlice` lineage |
| Transform provenance | Raw span plus transitional `SpanId` tricks | Many-to-many `OriginRelation` |
| Syntax representation | Semantic, lossy AST | Interval/claim substrate; no full AST yet |
| Ambiguity | Parser resolves into one semantic tree | Overlapping claims can remain unresolved until policy |

The relevant Doccer foundations are [TextSpan](D:/aipithicus/Doccer/src/Doccer/Core/TextSpan.cs:5), [TextMaster](D:/aipithicus/Doccer/src/Doccer/Core/TextMaster.cs:7), [TextSlice](D:/aipithicus/Doccer/src/Doccer/Core/TextSlice.cs:5), and [OriginRelation](D:/aipithicus/Doccer/src/Doccer/Origins/OriginRelation.cs:38).

My main architectural takeaway would be:

- Borrow Nushell’s cheap span-first stages, source slicing, recovery nodes, and propagation of provenance through diagnostics and lowering.
- Keep Doccer’s explicit master identity instead of adopting one process-global coordinate line.
- Keep `NodeId`, occurrence geometry, semantic-definition identity, and transform origin as separate concepts.
- Preserve a lossless claim/token layer—including trivia and competing interpretations—beneath any semantic AST.
- Let a semantic tree be a derived policy result, not the only surviving account of the source.

In other words, Nushell demonstrates how powerful spans become when every subsystem honors them. Its alias/`SpanId` history also demonstrates why Doccer should not collapse node identity, occurrence location, and origin lineage into a single “smart span.”

No files were changed.