# Old-tree → canonical reconciliation brief

**Status:** to review + re-implement · **Filed:** 2026-08-10

## Why this exists

reposnapshot's home is `science-facility/utils/reposnapshot` since the **2026-08-06
subtree migration** (canonical commit `23253d4`, from old `@58a1a264`). The stale copy
at `D:\aghado01\utils\reposnapshot` then accumulated a coherent **2026-08-09 work thread
(13 commits)** that never reached canonical. This brief inventories that thread for
**review-and-re-implement** — not blind copy: per the standing doctrine (LTS/old is not
authoritative), each delta gets an intent re-eval and improvement pass as it lands.

**Already consolidated this session (done, verified):** `shard-format-notes.md` (the
686-line codec spec), `lts-v3-transfer-audit.md` (corrections + quote-escaping bullet),
`reposnapshot-v3/schema/assemble.schema.json`, and the `opus-reposnapshotV3-LTS-updates.md`
capture. The items below are what remains.

## ⚠ Bidirectional-divergence rule

Canonical moved after migration too (`834b886` v3 updates; `3586584` "repoint live
absolute paths"). So:

- **Re-apply each delta ON canonical's current file and review for conflict — never `cp`
  old over canonical.** The verified-additive ones are safe; the rest need a merge.
- **Do NOT re-implement path-repointed / canonical-ahead files from old** — that would
  regress the migration path fixes. Those are: `README.md`, `.gitignore`, `.snapignore`,
  `_rs.scratch.md`, `rs.core.ingest.psm1`, `rs.core.internals.psm1`,
  `processors/chain-executor.ps1`, `processors/rs-indent.ps1`, `processors/tests/*`,
  `issues/v3/feedback/*`, `grok-*`, `toc-template/reports/*`, `TODO.md`s. They differ
  because canonical changed them.
- **Already shared (predate migration, in canonical):** colonel stream-collation +
  engine-state ban, the false-green fix (`tests/run-all.ps1`), the Bare fix.

Review a delta with `git -C D:/aghado01/utils/reposnapshot show <hash> -- <path>`.

## Fresh work — three themes

### A. Serializer codec / custom-container format spec
Commits `e25ee34 f8bf3db 4b8ef38 67d67af 2c23892 fb71567 113218d 8d4927b 2ad9628 54ee33b`.
The spec itself landed in `shard-format-notes.md` — **already migrated.** Supporting
deltas still to re-implement:

| File | Δ | What | Note |
|---|---|---|---|
| `reposnapshot-v3/rs.core.template.ps1` | +13 (`2ad9628`) | `{{#if Compaction}}` section + model-builder field — the cipher-key block, placed before the Tree block | CODE; canonical's template.ps1 also differs → **merge, confirm additive** |
| `issues/mcp-surface.md` | +16 (`54ee33b`) | MCP returns decoded spans ⇒ codec is a transport concern, not a reader concern, when a tool sits in the path | doc |
| `issues/v3/payload-manifest-ledger.md` | small | ledger **#16 (codec)** + **#17 (character encoding)** — declarations owed by the manifest | doc; merge |
| `issues/v3/v3-consolidation-plan.md`, `reposnapshot-v3/CHANGELOG.md` | — | plan status + dated records for the above | doc; merge |

### B. Encoding + codec siting doctrine
Commits `26ece11`, `ec0241c` — "encoding and codec are **serializer** declarations; file
the upstream look-back."

| File | Δ | What | Note |
|---|---|---|---|
| `reposnapshot-v3/processors/file-read.ps1` | +15 (`ec0241c`) | stamps `Encoding` (a constant decode policy) on every descriptor | CODE — **diff to confirm additive vs merge** |
| `reposnapshot-v3/rs.core.assemble.psm1` | +12 (`ec0241c`) | `Encoding` open-item docstring (rides into entry bags as a run-level constant; Header is its home until per-file detection lands) | CODE docstring — **verified purely additive** |
| `reposnapshot-v3/processors/rs-attributes.ps1` | +13 (`ec0241c`) | "CANONICAL UTF-8" docstring — SpanBytes measured UTF-8 by convention, serializer-invariant | CODE docstring — **verified additive** |
| `AGENTS.md`, `issues/v3/rs.core.assemble-design.md` | +8 / +44 | the doctrine in prose | doc; merge |

### C. Packing doctrine — "planning is not measurement" ★ resolves an open tension
Commit `1ef192d` — withdrew a prior packing adjudication; established **SpanBytes =
planning-grade** (ranking / skip / packing budgets), *not* the serializer's exact encoded
length.

| File | Δ | What |
|---|---|---|
| `reposnapshot-v3/processors/rs-attributes.ps1` | +7 (`1ef192d`) | SpanBytes-is-planning-grade note (same docstring block as B) |
| `AGENTS.md`, `issues/v3/rs.core.assemble-design.md` | +14 / +36 | planning-vs-measurement doctrine |
| `issues/v3/v3-consolidation-plan.md` | −9 | removed the withdrawn adjudication |

**★ This is the committed answer to the two tensions flagged in `opus-updates`**
(SpanBytes location; packing grade): SpanBytes **stays in `rs-attributes`** as a
planning-grade metric; the serializer owns only `length` + offsets. Re-implementing B+C
brings that resolution into canonical and **supersedes this session's "byte-exact packing
/ move SpanBytes to serialization" lean** — unless you deliberately re-open it. Decide
this first; it settles whether the `measure → plan → execute` bracket is even needed.

## Suggested sequence
1. **C** (packing doctrine) — smallest; resolves the tension; unblocks the serializer design.
2. **B** (encoding siting) — the `file-read` Encoding stamp + the two docstrings + doctrine (`rs-attributes.ps1` gets B+C in one block).
3. **A** (codec-spec support) — `template.ps1` Compaction section, `mcp-surface.md`, ledger #16/#17. (`shard-format-notes.md` already migrated.)

Note: `rs-attributes.ps1` carries **both** B and C in one additive docstring block — one edit covers both.
