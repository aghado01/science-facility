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
| `index` | position in an input sequence, 0-based | `par` rows, probe `shape each` |
| `bytes` | NUON-serialized UTF-8 length, computed once | probe `shape`; everything else calls it |
| `ok` | did this thing succeed — **universal on every record** | layer-wide (AGENTS.md 4a) |
| `error` / `trace` | short first line / full rendered error, on `ok: false` | layer-wide |
| `tag` | the name of a stored or handled thing | `jobs` registry, `stamp`, stash keys |
| `verb` | the producing command, dotted (`jobs.spawn`, `par.emit`, `xq`) | `meta.verb` |
| `spine` | `{key, n}` census of where the mass is | probe, rg |
| `stash` | put a payload in the registry | `jobs` |
| `payload quarantine` | keeping a big result out of context | doctrine — **always qualified**, see below |

## Renamed 2026-08-22

- **`meta.kind` → `meta.verb`.** `kind` was already spoken for three
  times over: the journal record kind (`turn | out | exit | note`,
  para-agent's, unrenameable), probe `page`'s `kind`
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
- **`kind`** survives in three unrelated closed sets (journal record,
  `page` unit, rg finding). Each is local to one shape and never
  appears in another; only the *stamp* sense was ambiguous, and that
  is now `verb`.
- **`quarantine`** — ours is *payload* quarantine, para-agent's is
  *commit* quarantine. Both legitimate; always qualified, never bare.

## Refused

- Coined phrases where a plain word exists (`deferred bodies` was
  reverted for this reason — nobody in software says it).
- Prefixing a field with its container (`history_index` as our own
  term; `job_seq`; `stream_turn`).
- Renaming a foreign field to suit us — it breaks the format-based
  coupling that makes us a drop-in journal producer.
