# `rs.core.crawler` — field groups and the standalone profile — brief

**Status:** filed, not started · **Filed:** 2026-08-23 · **Track:** independent;
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

They are not residue. Two things say so:

1. **They are free only at crawl.** All eight come off one `FileInfo` — one
   stat. Getting them later costs a fresh stat per survivor. Clause 4 of #38.
2. **Crawler has exaptation value on its own.** It has been wanted outside the
   RS pipeline before, and a filesystem walker's remit is filesystem facts. The
   RS pipeline's disinterest in a field is a *profile setting*, not evidence the
   field is wrong.

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
| `size` | `SizeBytes` (+ node `SubtreeBytes`) | on by default — the membrane's `MaxSizeBytes` gate and the subtree rollups both need it |
| `timestamps` | `LastWriteUtc` · `CreationUtc` | `LastWriteUtc` reaches the payload as core; `CreationUtc` is standalone-facing |
| `fsattrs` | `FsAttributes` | no RS consumer today; the obvious latent one is a membrane reparse-point / symlink test |

Node rollups follow their source group (`SubtreeBytes` with `size`;
`SubtreeDirCount` / `SubtreeFileCount` with `identity`).

The RS profile enables `identity + size + timestamps`; `fsattrs` is off until a
membrane test wants it. A standalone caller enables what it likes.

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
- Whether `skipped` records carry the same groups as `file` (they carry a
  subset today: `Path` · `Reason` · `Error`).
- Whether the standalone caller wants the node graph at all, or only the flat
  file list.
