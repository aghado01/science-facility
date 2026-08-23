The remediation should land as a short “composition hardening” sequence before `gh` or the first parallel query consumers. No implementation has started.

## 1. Freeze the semantics first

Create a narrow coordinating brief such as `briefs/composition-v1.md`. It should own only the cross-cutting rules; existing par/jobs, xq, rg, dataspection, and layering briefs remain canonical for their local commands and are amended in place.

Refine the doctrine:

- `ok` is universal on operation results, receipts, envelopes, and outcome rows—not arbitrary payload records such as metadata or rg findings.
- Engine completion and domain outcome remain distinct.
- Orchestration may summarize a returned domain outcome, but must retain the original value.
- No expected domain failure throws.
- A retrieval `tag` is published only after storage succeeds.

Recommended composition:

| Closure result                         | `par` row                            | `jobs` row                                               |
| -------------------------------------- | ------------------------------------ | -------------------------------------------------------- |
| Throws                                 | `ok:false`, `value:null`             | `status:failed`, `ok:false`, no output                   |
| Returns `{ok:false,...}`               | `ok:false`, original value retained  | `status:completed`, `ok:false`, output retained          |
| Returns outcome table with failed rows | aggregate `ok:false`, table retained | `status:completed`, aggregate `ok:false`, table retained |
| Returns ordinary value                 | `ok:true`                            | `status:completed`, `ok:true`                            |

For a table, aggregate only when every row has a boolean `ok`; ordinary tables remain ordinary successful values. Do not recursively interpret arbitrary nested structures.

This preserves the host’s existing distinction: `evaluate` succeeds and receives a history entry, while its returned data can contain `ok:false`.

## 2. Add two small core units

Add internal-only units, not façade exports:

- `core/outcome.nu`
  - Recognizes explicit record outcomes and outcome tables.
  - Returns a normalized summary with `ok` and a short error.
  - Does not modify or wrap the original value.

- `core/execution.nu`
  - Identifies whether the current invocation owns the foreground registry.
  - Distinguishes foreground, background-job, and `par` worker contexts.
  - Lets `par` carry “outer job owns the payload” into its workers.

Then update:

- `par` to lift returned failure outcomes while retaining `value`.
- `jobs spawn`/harvest to distinguish:
  - closure returned → `status:completed`;
  - closure threw/vanished → `status:failed`;
  - returned domain failure → completed with `ok:false`, payload still fetchable.
- `jobs cancel` missing/non-running paths to return explicit `ok:false` plus an error.

This should be the first implementation commit.

## 3. Make `jobs` authoritative for quarantine

Extend `jobs stash` with generated allocation, for example:

```nu
$payload | jobs stash --prefix "xq:nu"
```

Rules:

- `--tag` remains an exact caller-selected tag.
- `--prefix` asks `jobs` to allocate a unique human-readable tag.
- `jobs` returns the actual tag only after the row is stored.
- Generated allocation resolves collisions internally.
- Callers stop assuming that a tag suffix equals registry `seq`.
- Exact duplicates remain legible `ok:false` results.
- Registry-mutating verbs refuse execution from a context whose environment cannot propagate.

Migrate the complete call-site set:

- in-hand `read`
- `jobs emit`
- `xq`
- both `rg` quarantine branches

Remove `jobs list | length` and the `jobs list` imports from `xq` and `rg`.

Context behavior for an over-cap result:

| Context                                   | Behavior                                                                              |
| ----------------------------------------- | ------------------------------------------------------------------------------------- |
| Foreground registry owner                 | Stash and return verified tag                                                         |
| Background job, including `par` inside it | Return full value to the outer job; create no nested stash                            |
| Foreground `par` worker                   | Return `ok:false`, no tag, batch continues; advise wrapping the batch in `jobs spawn` |

That makes `jobs spawn { data | par { ... xq ... } }` the reliable large parallel pattern: one outer registry row, mixed failures retained, no worker-local phantom tags.

## 4. Harden capture and byte handling

Add a small internal `core/stream.nu` unit or equivalent focused helpers:

- String stream: UTF-8 byte length.
- Binary stream: actual byte length.
- Unsupported value: failure data, never zero bytes.

Amend `process capture`:

- Success includes `ok:true`.
- `ok` means capture succeeded, independently of child exit code.
- Preserve `cmd`, forwarded `args`, actual error, and trace.
- Streams are explicitly `string | binary`.
- Do not relabel every launch failure as “not found.”

Amend `xq`:

- Overall `ok:false` for capture failure, nonzero child exit, or quarantine failure.
- Preserve `exit_code` so child outcome remains inspectable.
- Binary streams obey the same cap and stash exact bytes.

Amend `rg`:

- Reject a binary process stream legibly.
- Detect `path.bytes`/`lines.bytes`.
- For this remediation, return an explicit unsupported-encoding failure rather than silently creating blank findings.
- Defer a larger byte-backed finding schema until there is a real consumer for it.

## 5. Add adversarial acceptance tests

Create `tests/composition-v1.nu`, plus local regression cases in existing suites:

- `par` with returned `ok:false`: outer row false, original value retained, siblings complete.
- `jobs spawn { xq missing }`: `status:completed`, `ok:false`, detailed payload fetchable.
- `jobs spawn { mixed | par ... }`: aggregate false, all rows fetchable.
- Thrown job remains `status:failed`, payload unavailable.
- Pre-seeded `xq:*`, `rg:*`, and `emit:*` tags cannot misroute retrieval.
- Foreground parallel over-cap calls return failure data with no phantom tag.
- Background job containing parallel over-cap calls creates exactly one registry row.
- Binary stdout larger than cap is stashed and fetched byte-for-byte.
- Byte-backed rg event never becomes `match:""`.
- Missing/non-running cancellation carries `ok:false`.
- Suite failure still exits nonzero at the test-process level.

## 6. Documentation and rollout gates

Each landing commit must update its docstrings, centralized references, and Claude/Grok/Codex adapters in the same change.

Also:

- Add a roadmap “composition hardening” gate between `rg` and item 6.
- Keep `gh-v1` unstarted until hardened `xq` lands.
- Block the first parallel query-envelope consumers until outcome aggregation and registry ownership are green.
- Session-host work can continue because it remains transport-only; add one eventual host test showing engine success with returned `data.ok:false`.
- Mark [sol-nu-core-review.md](/D:/aghado01/science-facility/issues/nushell-mcp/discussion/sol-nu-core-review.md:1) as historical and identify its review/remediation commits.
- Re-run module loading, config surface, external-cwd smoke, all suites, adapter parity, and a proper MCP live call when those tools are exposed.

## Pointed commit sequence

~~1. `nushell-mcp: freeze result composition contract`~~ 1c9eff5 nushell-mcp: freeze result composition contract
2. `nushell-mcp: compose outcomes through par and jobs`
3. `nushell-mcp: make jobs authoritative for payload quarantine`
4. `nushell-mcp: harden capture and rg byte paths`

The unrelated dirty `reposnapshot` files should remain untouched and every commit should stage named Nushell-MCP paths only.
