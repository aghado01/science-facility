# Schema derived from elements — brief

**Status:** filed, not started · **Filed:** 2026-08-15 · **Track:** V3 e2e sprint,
emission stage. Supplies the `schema` input to `row-grammar-brief.md`, so its
**contract** precedes that work even though its **derivation** can land after.

## The defect this closes

LTS carries two literal schema strings selected by a boolean
(`RepoSnapshotLts.psm1:2277-2281`):

```
idx<int> | path<str> | attributes:{char_count<int> word_count<int> whitespace_ratio<float> entropy<float>} | length<int> | content<str> |
idx<int> | path<str> | length<int> | content<str> |
```

That contradicts the format's own stated doctrine:

> Every payload is read on its own self-documented merits. Readers parse exactly
> what the header declares — never a fixed column set.
> — `shard-format-notes.md` §Configurability

A hardcoded schema makes "header and rows always agree" a property maintained by
discipline. Derived, it becomes true by construction — and it is what lets a new
enrichment processor's element reach the payload with no writer change, which is
the whole point of the open element model.

## The input already exists

`Invoke-Assemble` computes exactly what is needed and nothing consumes it yet:

- **Guaranteed core**, excluded from `Elements` by design: `RelativePath`,
  `NodePath`, `LastWriteUtc`, `Content`. The fixed part of any schema.
- **`Header.Elements`** — `@{ <name> = @{ Count; Total } }`, observed per-element
  presence across entries. The variable part, with its coverage already measured.

So the schema is: **core columns, always · observed elements, conditionally.**
The design work is entirely in that second word.

## The crux — partial presence

The format is positional: values only, no keys per row, framed by the length
prefix. So every row in a shard must carry the same column count. An element
present on only some entries therefore forces a choice:

- **(a) Column with an empty marker** for rows lacking it. Costs a delimiter per
  row per absent element, and needs an unambiguous empty representation.
- **(b) Excluded from the schema** unless universally present. Simple, and
  silently drops real data — which the payload would then be unable to declare.
- **(c) Per-shard schema.** The schema is already declared once per shard, in the
  header row. Nothing requires two shards to agree.

**(c) looks right and is worth serious consideration**, because it composes with
grouping rather than fighting it. Under `ByFileType`, a shard is homogeneous by
construction, so a language-specific element (a structural survey of `.cs` files,
say) is either present on every row of that shard or on none — and the schema
states which, honestly, per shard. The coverage number that would be 30% corpus-
wide is 100% in three shards and 0% in the rest.

It also sharpens what `Header.Elements` is for: corpus-level coverage
*diagnostics*, while each shard's header row is the local truth its rows must
match.

## Also to settle

- **Which elements become columns at all.** Not everything attached to a bag is
  row material. `Processing` is a receipt, `Encoding` is a run-level constant
  riding on every entry (consolidation §B 6e, unresolved). Likely a disposition
  per element rather than a blanket rule — and the disposition must not become a
  per-element branch in the writer, or the open element model is defeated.
- **Column order.** Must be deterministic, or payloads differ run to run for no
  reason. `Elements` is an ordered hashtable built in first-observed order, which
  is stable given stable ingest order but is an accident, not a guarantee.
- **Type annotations.** `idx<int>`, `path<str>`, `whitespace_ratio<float>` — LTS
  hardcodes them alongside the names. Derived, they come from inspecting values
  (fragile: an all-integer float column reads as `<int>`) or from a declaration
  the producing processor makes. The latter is more honest and implies processors
  describe their own elements.
- **Nested blocks.** `attributes:{…}` is positional-values-in-braces, so nested
  metadata repeats no keys. Generalizing that to arbitrary nested elements needs a
  rule, and a depth limit is likely wise.
- **Wire naming.** In-memory is PascalCase by doctrine; snake_case in the payload
  is a writer rendering decision (assemble-design open decision 2, narrowed). The
  mapping lives here.

## Contract

The schema object is consumed by **two** sinks and must be computed once:

- the **shard header row**, written by the row renderer
- the **tree manifest's `ColumnHeader`**, written by `rs.core.manifest`

Computing it twice would reintroduce exactly the class of defect
`row-grammar-brief.md` exists to remove. One object, two consumers.

## Exit gate

- A schema derived from a real IR reproduces the LTS column set for the
  equivalent configuration — proving the derivation is not merely different.
- An entry bag carrying a **novel** element reaches the payload as a column with
  **zero writer changes**. This is the open-element-model claim; it has never been
  tested end-to-end.
- Header row and every data row in a shard agree on column count, asserted rather
  than assumed.
- Column order is stable across repeated runs on identical input.
- Full battery green **and error stream clean**.

## Non-goals

- Emitting bytes — `row-grammar-brief.md`.
- Deciding 6e (`Encoding`'s home) — that disposition is entangled here and is
  flagged, not owned.
- The JSONL writer's schema, which comes free from its own serialization.

## Sequencing note

The row renderer needs a schema *shape* to consume, not the derivation logic. A
defensible order is: freeze the schema object's contract → build the renderer
against it with a fixed instance → land the derivation. That keeps the two briefs
independently landable while acknowledging the dependency, and avoids the row
work stalling behind the harder design.
