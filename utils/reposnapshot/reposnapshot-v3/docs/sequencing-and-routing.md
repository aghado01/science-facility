# Sequencing & Routing

One monolithic chain used to run over every ingested file. Now the caller names **capabilities**, the sequencer declares their canonical order and which of them route by file type, and the compiler resolves **one chain per distinct outcome** across the corpus. Each item is dispatched with the chain its extension resolved to. `chain_executor` is unchanged — it still walks the steps it is handed; what changed is that the steps differ per item.

Language-specificity exists only as data in `processors/default_sequencer.json`, read only by the compiler.

## The two-layer contract

These are independent and must not be conflated:

1. **Correctness — precondition self-sufficiency.** Each processor establishes its own preconditions (see [mutator-contracts.md](mutator-contracts.md)); some operations therefore run redundantly across processors. That is deliberate, and it is what makes *every* chain valid by construction, including one with a slot spliced out. No stage may assume its canonical predecessor ran. The day this erodes, per-file variation silently breaks for exactly the chains that omit a stage.
2. **Canon — nominal ordering.** `Group` and `Rank` order the nominal path for quality and non-waste. Placement is derived, not taste: **A follows B if B can produce output violating A's postcondition.** Stripping emits trailing whitespace, so tidy follows strip; measurement describes the content rendered downstream rather than the raw input, so it runs after every mutation.

Correctness never depends on the canon. The canon exists so the nominal run is clean and a reading agent can rely on a stable story.

## The sequencer

`processors/default_sequencer.json`. One entry per **slot** — a capability, named for what it does rather than which file implements it.

```json
{
  "Processors": {
    "file_read":       { "Group": 1, "Rank": 0, "Default": true, "File": "file_read.ps1" },
    "StripComments":   { "Group": 2, "Rank": 0, "Requires": ["file_read"],
                         "Routing": [
                           { "File": "rs.ps.strip.ps1", "Extensions": ["ps1","psm1","psd1"] },
                           { "File": "rs.cs.strip.ps1", "Extensions": ["cs","csx"] }
                         ] },
    "Indentation":     { "Group": 3, "Rank": 1, "Requires": ["file_read"], "File": "rs.indent.ps1" },
    "Whitespace":      { "Group": 3, "Rank": 2, "Requires": ["file_read"], "File": "rs.whitespace.ps1" },
    "ContentMetadata": { "Group": 4, "Rank": 0, "Requires": ["file_read"], "File": "rs.content_meta.ps1" }
  }
}
```

**Routed-ness is structural.** A slot carries either a `File` (fixed — one implementation) or a `Routing` array (routed — one per file class). There is no sigil to interpolate and no separate route table to fall out of sync.

**Ordering is declared at two levels, and never inferred from layout.** `Group` ranks families; `Rank` orders members within one. `Rank 0` reserves a group for a single member. The `Processors` object's *key order* is not data — alphabetizing it changes no chain — while editing a `Group` or `Rank` changes chains exactly as intended.

**`Requires` drives enablement, not order.** Naming a slot pulls in what it requires; `Default: true` slots come along unnamed. Order still comes from `Group`/`Rank`, which is why every `Requires` edge must point backwards through the canon — otherwise a dependency would be enabled and then run too late.

### Enforced at load

Every one of these is terminating. A malformed sequencer is a stop, not a degraded run.

| Rule | |
|---|---|
| `Group`/`Rank` | must parse as integers |
| Exactly one of `File`/`Routing` | both, or neither, is a declaration bug |
| Declared files | must exist on disk *and* match the filename the manifest holds — catching a right-stem/wrong-extension typo, not just an absent processor |
| Extensions | dot-less in the file, normalized to leading-dot lowercase on load |
| Occupancy | no two routes under one slot may claim the same extension; separate slots claiming it is legitimate |
| `Rank 0` | reserves its group for one member; otherwise ranks within a group are distinct |
| `Requires` | targets exist, and sort strictly earlier |

## Compilation

`Resolve-Chain` walks the canon **once per extension**, testing occupancy at the slot where it matters and emitting ordered steps in the same pass. A routed slot no route claims is **spliced out** — dense lists, never tombstones. A null placeholder is explicitly rejected: it would force the executor to know what a hole is.

`Resolve-Family` interns those chains. Interning is a **cache over unique extensions, not a relation**: chains that compare equal share an entry, so `.ps1`/`.psm1`/`.psd1` collapse because their compiled chains agree — not because anything about their names stringifies alike. Comparison is **positional**, not `Compare-Object`, which defaults to set semantics and would merge two chains differing only in order.

Ids are **opaque ordinals**. Nothing may parse, match on, or display them as if they named a processor; the chain carries meaning, since every step names the `Slot` it fills beside the `Key` that filled it. Ordinals rather than guids because the payload's determinism is asserted elsewhere — the same corpus must intern identically on every run.

```
6 extensions  →  3 chains

  chain[0]  len=4   file_read > rs.indent > rs.whitespace > rs.content_meta
  chain[1]  len=5   file_read > rs.cs.strip > rs.indent > rs.whitespace > rs.content_meta
  chain[2]  len=5   file_read > rs.ps.strip > rs.indent > rs.whitespace > rs.content_meta

  .ps1 .psm1 → chain[2]      .cs → chain[1]      .md .py .ts → chain[0]
  no extension / unknown     → chain[0]
```

### Pass-through is a chain, not a failure

Requesting `StripComments` over a mixed corpus means *strip where a stripper exists*. Everything else flows through the rest of the canon, one step shorter — the N-1 chain above. That chain is **always compiled**, even when every corpus extension happens to be routed, because a file with an unknown extension or none at all (`Makefile`, `LICENSE`) must still have somewhere to go. Pruning it as "unused" is a false economy that strands exactly those files.

## Dispatch

- **Slicing stays round-robin**, with a third parallel array carrying each item's chain id. Round-robin remains right under a family: every worker gets a representative mix, so cost-skew between chains never concentrates in one slice.
- **Routing reads the `Extension` the crawler stamped** — measured at the point of authority, never re-derived from the path.
- **One RunspacePool from one ISS**, registering the union of processors across all chains — both strippers, for a mixed corpus.
- **The family is marshalled once** and shared by reference; workers build an id → plan table at startup, so per item, plan selection is a lookup, never a decision. Workers treat the family as immutable. Total plan storage is C chains, never N.
- **Unchanged**: `chain_executor.ps1`, `bag_helpers.ps1`, budget resolution, bin packing, stream harvesting, the index-stable envelope.

Routing resolves before `file_read` runs, so it can never depend on content — no shebang sniffing for extensionless files. Extension-only routing is the v1 call; the escape hatch (hoist `file_read` into a fixed prologue and route on the post-read bag) is a known shape, not a planned one.

## Caller surface

`-IncludeProcessors` is a **set** of slot names — array position carries no meaning. This is [rs.whitespace](whitespace-invisibles.md)'s `Operations` model one scale up: there the caller lists which ops run and the source fixes the sequence; here the caller lists capabilities and the sequencer fixes it. Selection is the caller's, sequence is the implementation's, at both scales.

`-RunVerbatim` runs a literal `-Processors` chain in the order given, identically for every file, with nothing routed — so a language-specific processor named there runs on every file regardless of extension, which is the point. It is the instrument for deliberately violating this format's invariants, and the two modes are not interchangeable: `-Processors` without it is refused, and it without `-Processors` is refused.

`file_read` is a prologue in both modes, prepended under verbatim unless the caller places it. Without it a chain reads nothing and returns zero entries with no error — the wrong kind of quiet. Verbatim exists to break order and routing, not to run against unread files.

The three chain cautions live **only** under verbatim. Under the sequencer they are compiler guarantees — `rs.content_meta` lands last because its `Group` says so — and an omission is a request the caller made rather than an accident to warn about.

## Reporting

The `Processing` trail names the **capability**, with the implementation alongside:

```
Processor: StripComments    Implementation: rs.ps.strip
```

That is the fact a reading agent needs — comments were stripped — and `StripComments` says so whichever language implementation ran, without losing per-entry provenance. The slot reaches the processor through its config, injected by the compiler's bind loop, because a routed processor cannot know which capability it was chosen for. A processor invoked standalone has no slot and reports its own name.

The tree's `## Chains` section (rendered by `New-Manifest` from the colonel family) reports per chain, not one chain: the distinct chains and which extensions took each, with `Slot (Key)` when the capability name and processor file differ. Unused pass-through is plan bookkeeping and is omitted. A single `Chain` field cannot describe a run where files took different chains.

## Invariants

1. No component below plan compilation branches on file type. The compiler alone reads the sequencer; the colonel applies an opaque map; the executor iterates what it is given.
2. Stages self-establish preconditions (correctness); the canon orders the nominal path (quality). Neither substitutes for the other.
3. Chains are dense — splice, never tombstone.
4. Chain ids are opaque identities. Cross-chain and cross-run identity is by slot or processor key, never by position or by parsing an id. Chains of unequal length coexist in one run.
5. The shared family is immutable in workers.
6. Pass-through is always compiled. "No route claims this file" is an expected outcome, not a failure.
7. Ordering is declared, never inferred from layout: `Group`/`Rank` are authoritative, the `Processors` key order is incidental.
8. Every processor is classified by its single sequencer entry. `configs/` carries no ordering metadata; classification is structural.
9. Each stage's postcondition states which byte accounting survives it (`SpanBytes` vs `SizeBytes` — see [content-metrics.md](content-metrics.md)).

## Adding a language

A stripper for a new language is a processor file, its `configs/<key>.json`, and one route under `StripComments`. No code changes anywhere: the compiler picks it up, files of that extension leave pass-through and get their own chain, and the ISS registers it alongside the others. Until then those files are not an error — they simply pass through.
