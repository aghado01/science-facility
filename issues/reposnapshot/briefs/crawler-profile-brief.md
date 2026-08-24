# `rs.core.crawler` — field groups and the standalone profile — brief

**Status:** filed, not started *(the rollup-layer move was carved out and
landed 2026-08-23/24 — see the ledger; §Rollups below keeps only what this
brief still needs)* · **Filed:** 2026-08-23 · **Track:** independent;
**after** `rs.core.shards`, deliberately (§Sequencing) · **Doctrine:** ledger
#38 (four clauses, amended 2026-08-23), #50 (the carried tier), #31 (stages
stamp what is free at their vantage) · **Prompted by:** the crawl-vs-ingest
read-ahead, 2026-08-23.

## The problem

Crawler stamps eight facts per file. Two of them — `CreationUtc` and
`FsAttributes` — have **no reader at any stage of the RS pipeline**: they are
declared as pass-throughs in `membrane.contract.json` and
`ingest.contract.json`, and dropped by `assemble`'s exclusion list. They read as
residue.

They are not residue — but the reason is narrower than it first looks, and worth
stating precisely because the weak version of it is tempting.

**The weak version:** "they are free only at crawl, so keep them." All eight do
come off one `FileInfo`, and ingest holds no filesystem object at all
(`file-read.ps1` reads by path — no `FileInfo`, no retained handle), so a fact
crawl did not stamp genuinely costs a fresh syscall downstream. But a stat is
~1–2 µs; at a thousand survivors that is single-digit milliseconds for an entire
run. **The syscall count does not carry the argument.** Nor does availability
(#38 clause 0): neither field feeds a subtree rollup, so unlike `SizeBytes`
neither is crawl-only by construction.

**The version that stands:** crawler has **exaptation value on its own**. It has
been wanted outside the RS pipeline before, and a filesystem walker's remit is
filesystem facts. The RS pipeline's disinterest in a field is a *profile
setting*, not evidence the field is wrong. That argument needs no help from the
other two, and the live question these fields raise is **whether to gather
them** — which is this brief's — not *where*, which #38 already settles.

So the fix is not to delete them and not to leave them silent — a field with no
reader reads as an oversight to the next person. The fix is to make what crawler
gathers **configurable**, so an unused field is an unselected option rather than
dead weight, and so the standalone use is a first-class caller rather than a
fork.

## Shape

`crawler.out.file` splits into **field groups**, selected by a param:

| group | fields | disposition |
|---|---|---|
| `identity` | `AbsolutePath` · `RelativePath` · `NodePath` · `Extension` | **always on** — the record's identity and the membrane's blacklist key; nothing works without it |
| `size` | `SizeBytes` | on by default — the membrane's `MaxSizeBytes` gate and the rollup layer both need it |
| `timestamps` | `LastWriteUtc` · `CreationUtc` | `LastWriteUtc` reaches the payload as core; `CreationUtc` is standalone-facing |
| `fsattrs` | `FsAttributes` | no RS consumer today; the obvious latent one is a membrane reparse-point / symlink test |

The rollup layer is not a field group — it toggles emit / do-not-emit whole
(landed 2026-08-23; see §Rollups below). Its dependency edge stands: a profile
without `size` cannot offer `SubtreeBytes` at any setting.

The RS profile enables `identity + size + timestamps`; `fsattrs` is off until a
membrane test wants it. A standalone caller enables what it likes.

## Rollups: already a keyed layer — record in the ledger, not here

The subtree rollups left `out.node` for `out.rollups` = `@{ Condition;
ByNode[NodePath] }` (landed 2026-08-23; vocabulary corrected to
condition/grouping 2026-08-24). The record lives in
[planning/ledger.md](../planning/ledger.md) and the doctrine in #52 — this
brief does not restate either. What remains relevant *to this brief*:

- **The layer toggles whole** — emit / do-not-emit, never a conditional `from`.
  That is why the move was carved out and landed ahead of this brief: it
  removed the expensive part of making rollups configurable.
- **Dependency edge**: the layer aggregates `SizeBytes`, so a profile without
  `size` cannot offer it at any setting.
- **The callable** (one definition, N conditions) is trigger-gated in
  [roadmap §Deferred](../planning/roadmap.md) together with the atom retention
  it depends on (`SizeBytes` → `carried`, #50) — not this brief's scope.

## The bill — this is the part that is not free

Making the crawler's output shape configurable makes the **contract graph
conditional**, and the generic suite is what pays:

- `membrane.out.file.CreationUtc { "from": "crawler.out.file" }` is checked
  unconditionally today. Under groups it must become conditional, and every
  downstream stage must tolerate absence.
- The vocabulary already has `"optional": true` (serialize's `Buffering`,
  ingest's skipped `SizeBytes`), so the *mechanism* exists — but
  `contracts.tests` must learn that an optional field's absence is **legal**
  rather than a broken `from`, and the crawler contract needs a group
  declaration the other stages do not have.
- Consequence worth stating plainly: **crawler stops being an RS stage that
  happens to be reusable and becomes a component with its own profile surface.**
  That is the intent, but it is the one stage carrying a config dimension the
  others lack, and the suite that checks all of them has to know about it.

## Sequencing — after shards, not before

Nothing in `rs.core.shards` depends on this. `ByFileType` needs `Extension`,
which is in `identity` and always on (and now rides the carried tier, #50).
This is also the **only** item in the current backlog that can destabilise a
green generic suite, since it changes what `contracts.tests` accepts rather than
what any one contract says. Doing it while the export phase is mid-build would
put two moving pieces under one gate.

## Exit gate

- Crawler with the RS profile produces **byte-identical** output to today's
  crawler on the same tree — the default profile is not a behaviour change.
- A profile that omits a group produces descriptors without those fields, and
  membrane/ingest pass them through without error.
- `contracts.tests` distinguishes *"optional field legally absent"* from
  *"`from` does not resolve"*, and fails on the second — verified **negatively**,
  by breaking a `from` on purpose and watching it fail.
- The blacklist and `MaxSizeBytes` gates still fire under every profile that
  claims to support them; a profile that omits `size` must make
  `-MaxSizeBytes` an error rather than a silent no-op.
- Battery green; error stream clean; count recorded with the commit.

## Non-goals

- New crawl-time facts. This is about making the existing eight selectable, not
  about gathering more.
- Content sniffing at crawl — permanently out (#30: the crawler walks
  `.git`/`node_modules`/build output, often 10–100× the surviving count).
- A general plugin surface for crawler. Groups are a fixed roster, not an
  extension point.

## Open calls

- Whether the group param is a switch set (`-With timestamps,fsattrs`) or a
  profile name. A name is a tuple with a label, and #40 is on record about how
  that goes — leaning switch set.
- Whether `fsattrs` should ship **on** with a membrane reparse-point test built
  at the same time, which would retire the "no reader" question outright rather
  than deferring it.
- Whether the rollup layer is a profile **toggle** rather than a field group.
  Once it is a keyed layer rather than node fields, "off" means the layer is not
  emitted — no absent-field handling, no conditional `from`. That is a smaller
  change to the contract graph than a field group, and it may be the reason to
  do the layer move *before* the profile work rather than alongside it.
  The dependency edge survives either way: rollups are derived from `SizeBytes`,
  so a profile without `size` cannot offer `SubtreeBytes` at any setting.
- **Adjacent, and not the same question:** `membrane.out.node.CompiledState`
  (`@{ Semantics; Positives; Exceptions }`) is also derived material stamped onto
  a graph node. It is not an aggregate — it is the stage's own working state, and
  genuinely per-node under nested ignore files — so #52 does not reach it. Worth
  asking separately whether it should ship in `out` at all, or whether it is
  membrane-internal.
- Whether `skipped` records carry the same groups as `file` (they carry a
  subset today: `Path` · `Reason` · `Error` — note `membrane.out.skipped` and
  `ingest.out.skipped` *do* carry `SizeBytes` and `Extension`, so the atoms of
  the discarded set survive even though the crawler's own skip records are
  thinner).
- Whether the standalone caller wants the node graph at all, or only the flat
  file list.
