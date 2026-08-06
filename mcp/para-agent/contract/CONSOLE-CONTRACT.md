# Console Journal Contract v1

A format-based contract, in the sense of `ARCHITECTURE.md` Principle 2: consumers depend on this schema, never on the code that produced it. Any producer that emits conforming records is a valid source, and the reader must not care which one wrote them.

## Design priorities

In order, because they conflict and the order decides the conflicts:

1. **No silent omission.** A reader may return less than everything, but never without saying so, how much, and how to get the rest. A truncation that does not announce itself is a bug, not an optimisation.
2. **Token economy.** The default read is a summary. Bodies are opt-in. Scanning 200 turns should cost less than reading one of them.
3. **Selectivity.** Find, filter, slice, and query without paying for the whole stream.
4. **Facility.** The common case — "what happened since I last looked" — is one call with one integer.

Governance, policy and oversight are explicitly **out of scope**. This is a control-plane data contract.

## Storage layout

```
<root>/streams/<stream>/
    journal.jsonl          append-only, one record per line, seq-ordered
    turns/000017.out       output bodies, byte-exact, referenced by seq
    turns/000017.done      completion sentinel (also the wake signal)
    turns/000017.cancel    cooperative cancellation request
```

`journal.jsonl` is append-only and never rewritten. Bodies live outside it so the journal stays small enough to scan cheaply — the single most important decision in this contract.

## Records

Every record carries the same envelope:

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Schema version. `1`. |
| `seq` | int | Monotonic, gap-free, per stream, assigned by the writer. **This is the cursor primitive.** |
| `ts` | string | ISO 8601 with milliseconds, UTC. |
| `stream` | string | Logical stream id, normally the pane's session name. |
| `turn` | int | Groups the records of one command. Correlation is explicit, never inferred from adjacency. |
| `kind` | string | `turn` \| `out` \| `exit` \| `note` |

### `kind: "turn"` — a command was dispatched

| Field | Type | Meaning |
|---|---|---|
| `cmd` | string | Command text as submitted, verbatim. |
| `cwd` | string | Working directory at dispatch. |
| `shell` | string | Dialect: `pwsh` \| `bash`. |
| `cmd_hash` | string | 8-hex of SHA-256 over `cmd`. Cheap identity for dedup and recall. |
| `origin` | string | `run` \| `exec` \| `interactive` — who typed it. |

### `kind: "out"` — output produced by a turn

| Field | Type | Meaning |
|---|---|---|
| `bytes` | int | Exact byte length of the body. |
| `lines` | int | Line count. |
| `out_hash` | string | 8-hex of SHA-256 over the body. |
| `text` | string? | Body **inlined**, present only when `bytes <= inlineLimit` (default 2048). |
| `ref` | string? | Relative path to the body file, present when the body was not inlined. |
| `preview` | string? | First 200 characters, present whenever `ref` is. Never the only copy of anything. |
| `truncatedInline` | bool | Always `false`. The field exists so its absence can never be mistaken for silent truncation. |

Exactly one of `text` or `ref` is present. A body is never partially inlined — `preview` is an addition to `ref`, never a replacement for it.

### `kind: "exit"` — a turn finished

| Field | Type | Meaning |
|---|---|---|
| `code` | int\|null | Process exit code. `null` when the shell had none to report (a pwsh cmdlet that ran no native command). Never coerced to 0. |
| `ok` | bool | Shell-level success (`$?` / `$?`-equivalent), independent of `code`. |
| `duration_ms` | int | Wall clock from dispatch to completion. |
| `outcome` | string | `completed` \| `cancelled` \| `timeout` \| `died` |

A turn without an `exit` record is still running, or its producer died. Those are distinguishable: an `exit` with `outcome: "died"` is a producer that noticed; a missing `exit` is one that did not.

### `kind: "note"` — producer-level events

Session start/stop, resize, capture gaps. Carries `note` (string) and optional `data` (object).

A producer that knows it lost data **must** emit a `note` saying so. A gap the reader cannot see is a silent omission.

## Receipts

Every read returns a receipt. It is not optional and not conditional on something having been withheld — an unconditional receipt is what makes its absence detectable.

```json
{
  "op": "log",
  "stream": "agent-agy",
  "cursor": { "from": 100, "to": 137, "next": 138 },
  "counts": { "scanned": 412, "matched": 96, "returned": 38, "withheld": 58 },
  "bytes": { "returned": 2104, "withheld": 918233 },
  "complete": false,
  "withheld": [
    { "reason": "limit", "count": 58, "retrieve": "log(from: 138)" },
    { "reason": "body not inlined", "count": 12, "retrieve": "body(seq: <n>)" }
  ]
}
```

Rules:

- `complete: true` is a promise that nothing matching the query was left out. It is the only thing a consumer needs to check.
- `withheld` is empty **iff** `complete` is true.
- Every `withheld` entry names a concrete call that retrieves what it describes. "Some results omitted" without a retrieval path is a contract violation.
- `counts.scanned` distinguishes "nothing matched" from "we did not look" — a query that examined 0 records and one that examined 4000 and matched none are different facts.

**Deferred bodies are not omissions.** A record whose body exceeded `inlineLimit` is still returned whole, carrying `ref` and `preview`; only the body sits elsewhere. Those are reported in a separate `deferredBodies` array and do **not** flip `complete`. The distinction matters practically: if a referenced body made a read incomplete, `complete` would be false for nearly every read containing real output, and a flag that is almost never true stops being worth checking. Both fields are always present, so nothing is hidden either way.

```json
"deferredBodies": [ { "turn": 4, "bytes": 43893, "lines": 5000, "retrieve": "body(turn: 4)" } ]
```

## Cursors

A cursor is an integer: the `seq` a reader has consumed through. `from: N` means every record with `seq >= N`.

This works because the journal is append-only and `seq` is gap-free, so a reader's seen-set is always a prefix and needs no set structure to represent. Readers hold their own cursor; the producer stores no per-reader state.

Sparse acknowledgement is deliberately not supported. If it is ever needed, it belongs in a reader-side index, not in this contract.

## Producers

**`run` / `exec` (para-agent).** Redirects the command's own output to `turns/<seq>.out` and writes `turns/<seq>.done` on completion. Body is byte-exact because it never passes through a terminal: no wrapping, no width truncation, no trailing-whitespace loss, no scrollback ceiling. The pane still displays output for human eyes; the file is what the supervisor reads. Needs no installation.

**Interactive capture (optional).** A shell profile hook for commands typed into a pane directly, by a human or an agent driving a REPL. Covers what `run` cannot see. Known gap: PowerShell `Write-Host` writes to the host rather than the pipeline, so an `Out-Default` proxy will not observe it — a conforming producer must emit a `note` acknowledging that limitation rather than pretending coverage is total.

## Signals

`turns/<seq>.done` — written by the producer on completion, containing `{code, ok, duration_ms, outcome}`. Its appearance is both the completion record and the wake signal: cheap to poll with a stat, and watchable with `fs.watch` for zero-latency detection.

`turns/<seq>.cancel` — written by a consumer to request cooperative cancellation. The producer polls it and stops itself. Cooperative only: a command that does not check it is unaffected, and forcible termination remains a separate escalation. Writing it is advisory, never a guarantee.
