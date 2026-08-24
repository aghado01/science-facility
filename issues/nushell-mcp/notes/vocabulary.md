# Vocabulary — whose word is it

**Written:** 2026-08-22 · **Status:** binding on every brief, module
docstring, and reference page. Amend here, then sweep.

Most drift in this layer comes from one confusion: **a foreign field
name used as if it were our concept.** The rule is:

> Quote a foreign name **verbatim and attributed**, only where you mean
> that exact field. Never adopt it as the name of our concept — our
> concept gets our own unprefixed name.

## Foreign — quote, never rename, never adopt

| Term | Owner | Means | Our concept for it |
|---|---|---|---|
| `history_index` | nushell `--mcp` tool result | the slot a **successful** evaluate's value took in `$history` | just **`index`** — probe's `shape each` column; in prose, "the `$history` index" |
| `timestamp`, `cwd`, `output` | same tool result | as named | host journal `ts`, `cwd`, `out` |
| `seq`, `turn`, `kind`, `cmd`, `ref`, `preview` | para-agent Console Journal Contract v1 | journal record envelope | adopted wholesale — we are a *producer* of that format |
| `$history` | nushell | the engine's evaluation buffer | ours to index into, not to rename |

**`history_index` is the canonical example.** It is nushell's field, and
it counts only successes. Our word for "position in `$history`" is
`index`, unprefixed. Write "`index` — for `$history`, the same slot the
tool result reports as `history_index`", never "the history_index" as
if that were the idea's name. Prefixing a container's name onto its
index is exactly the ornament to avoid.

## Ours — one sense each

| Term | Sense | Where |
|---|---|---|
| `index` | position in an input sequence, 0-based | `par` rows, dataspection's `shape each` |
| `bytes` | NUON-serialized UTF-8 length, computed once | agent-facing: `shape`. Internal measurement: `value nuon` in `core/value.nu`. `par`/`jobs` call `shape`, not `value nuon` |
| `ok` | did the operation represented by this outcome-bearing result succeed | operation results, receipts, envelopes, and outcome rows; not arbitrary payload records |
| `error` / `trace` | short first line / full rendered error, on `ok: false` | layer-wide |
| `outcome` | an explicit top-level boolean `ok`, or a top-level table whose every row has boolean `ok`; may be summarized but the original value is retained | composition through `par` / `jobs` |
| `status` | execution lifecycle, not domain success | `jobs`: `pending \| running \| completed \| failed \| cancelled` |
| `tag` | the name of a stored or handled thing; a retrieval result publishes one only after storage succeeds | `jobs` registry, `stamp`, stash keys |
| `registry owner` | the persistent foreground context whose `$env.JOBS` mutation survives the command | payload-quarantine composition |
| `verb` | the producing command, dotted (`jobs.spawn`, `par.emit`, `xq`) | `meta.verb` |
| `inspect` | **portable verb** — describe without disclosing | `jobs inspect`, `nu-modules inspect`; on a value in hand: `shape` |
| `read` | **portable verb** — disclose the body; the one cap rule (inline if it fits, else a receipt naming the retrieval) | `jobs read`, `$x \| read`; over-cap retrieve is `jobs fetch <tag>` |
| `fetch` | uncapped retrieve of a stored payload | `jobs fetch` — not portable `read`; compose `jobs fetch t \| page` |
| `preview` / `page` | **portable verbs** — bounded disclosure: leaves clipped / one slice | dataspection |
| `stamp` | **portable verb** — write this metadata onto it; always qualified by its object | `meta stamp` (dataspection) |
| `meta` | the provenance stamped onto a record — a **noun**, like `shape`. Not nushell's `metadata` builtin (pipeline `{span}`, stripped on storage) | dataspection |
| `shape` | the census core `{type, length, bytes, columns?}` | dataspection; jobs inspect fills payload fields from it internally |
| `spine` | `{key, n}` census of where the mass is | dataspection, rg |
| `stash` | put a payload in the registry | `jobs` |
| `payload quarantine` | keeping a big result out of context | doctrine — **always qualified**, see below |
| `stdout_bytes` / `stderr_bytes` | byte length of the captured terminal stream value: UTF-8 length for string, byte length for binary | `xq`; deliberately not the unqualified NUON census `bytes` |

An **outcome-bearing boundary** is a role, not a record type. A command
result or orchestration row carries `ok`; an rg finding, census/budget
record, arbitrary stored payload, or `meta` sub-record does not acquire
`ok` merely because it is a record. Engine completion and returned
domain outcome remain separate facts. The projection and storage-owner
rules are specified in
[composition-v1](../briefs/composition-v1.md).

## Renamed 2026-08-22

- **module `probe` → `inspect` → `dataspection`** (2026-08-22).
  Named for the practice, not its contents — `jobs`/`nu-modules` are
  domain modules, this one is a discipline. `inspect` was wrong as a
  module name because it is a *portable verb* that appears in other
  domains. Membership: operates on a value **in hand** → here;
  addresses a **stored or named** thing → that thing's domain.
  Earlier reasoning kept for the trail: "Probe" was a coined word for a thing
  the layer already named twice (`jobs inspect`, `nu-modules inspect`).
  `inspect` = *tell me about it, don't give it to me*; its partner is
  `read`. The module exports no `main`, so nushell's builtin `inspect`
  (a debug **passthrough**) is not shadowed. `probe` survives only as a
  private helper name — renamed to `load-unit` in `nu-modules` to keep
  the word out of circulation.

- **`jobs inspect` is not `read | shape`** (2026-08-22). Inspect
  discloses nothing; `read` may decline, and then `| shape` would
  census the receipt. Jobs keeps its own inspect receipt and may call
  `shape` on the stored payload internally so `bytes` is one
  definition. `jobs read t | shape` is compose after a lawful
  disclose. Load order is runtime primitives first (`par`, `jobs`),
  then the access discipline (`dataspection`); over-cap `read` stashes
  through `jobs stash`.

- **`meta.kind` → `meta.verb`.** `kind` was already spoken for three
  times over: the journal record kind (`turn | out | exit | note`,
  para-agent's, unrenameable), dataspection `page`'s unit
  (`rows | lines | chars`), rg `findings.kind` (`match | context`).
  The stamp field's values are verb names, so `verb` is both precise
  and collision-free. Consequence: the host's `log {kind?}`
  unambiguously filters the **journal record kind**; filtering by
  producing verb is `log {verb?}`.

## Collisions kept, deliberately

- **`seq`** has two senses: the journal's gap-free record cursor
  (contract) and `jobs`' spawn order (ours, landed and tested). They
  nest rather than compete — a journaled jobs receipt is
  `{seq: 42, kind: out, …}` whose body holds `{seq: 0, tag: sq, …}`.
  Renaming landed code to fix a nesting is not worth it; say which
  `seq` you mean when both are in view.
- **`kind`** survives in four unrelated closed sets (journal record `turn | out | exit | note`, `page` unit `rows | lines | chars`, rg finding `match | context`, `nu-skills list` row `leaf | branch`). Each is local to one shape and never appears in another; only the *stamp* sense was ambiguous, and that is now `verb`.
- **`quarantine`** — ours is *payload* quarantine, para-agent's is
  *commit* quarantine. Both legitimate; always qualified, never bare.

## Refused

- Coined phrases where a plain word exists (`deferred bodies` was
  reverted for this reason — nobody in software says it).
- Prefixing a field with its container (`history_index` as our own
  term; `job_seq`; `stream_turn`).
- Renaming a foreign field to suit us — it breaks the format-based
  coupling that makes us a drop-in journal producer.
