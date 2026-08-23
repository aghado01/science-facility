# nushell-mcp — decisions

Living register of **rulings**. Briefs remain the specs; this file records
what is decided, superseded, or still open — it does not restate
[`AGENTS.md`](../../../mcp/nushell-mcp/AGENTS.md) or a brief.

**Ahead:** [../roadmap.md](../roadmap.md) · **Done:** [ledger.md](ledger.md)
· **Specs:** [../briefs/](../briefs/) · **Trail:** [../discussion/](../discussion/),
[../notes/](../notes/)

Status: **ruled** = owner ruling · **carried** = adopted with a brief ·
**landed** = in code at the cited commit · **OPEN** = awaiting ruling ·
**parked** = not now, rationale kept.

Amend in place. Newest thinking wins; when a row is wrong, date the
amendment, do not fork this file.

| # | Status | Decision |
|---|---|---|
| N18 | carried | Terminal streams are string or binary and are measured as returned; unsupported values fail closed. Ripgrep byte-backed JSON is explicit unsupported-encoding failure in this cut. [composition-v1](../briefs/composition-v1.md) |
| N17 | carried | The persistent foreground registry allocates generated tags and callers publish a retrieval `tag` only after storage succeeds. Background jobs and parallel workers never claim local registry mutation persisted. [composition-v1](../briefs/composition-v1.md) |
| N16 | landed | `ok` is universal at outcome-bearing boundaries, not arbitrary records. `par` / `jobs` summarize declared returned outcomes while retaining the original value; jobs lifecycle `status` remains separate. [composition-v1](../briefs/composition-v1.md) 2026-08-23 |
| N1 | landed | `nu --mcp` is the engine protocol, not the product surface. Thin host later. [session-host-v1](../briefs/session-host-v1.md) |
| N2 | landed | This package designs one MCP user's console plus an embedding surface. Integration is para-agent's. [launch-surface](../notes/launch-surface.md) |
| N3 | landed | Portable verbs (`inspect`, `read`, `preview`, `page`, `stamp`) are meanings. In-hand vs addressed is membership, not a second vocabulary. [vocabulary.md](../notes/vocabulary.md) |
| N4 | landed | One `bytes` definition: NUON UTF-8 length via `shape`. [dataspection-v1](../.archive/briefs/dataspection-v1.md) `5381bf3` |
| N5 | landed | `jobs inspect` is not `jobs read \| shape`. Inspect calls `shape` internally. `058f887` |
| N6 | landed | `par cap` is the one inline/query cap resolver. `058f887` |
| N7 | landed | In-hand `read` and `jobs read` share the cap rule. Retrieve is `jobs fetch <tag>` (was `--full`, N10). |
| N8 | landed | Overlay `use *` is not dependency injection into module bodies. Config.nu composes the agent surface. Witness: `$x \| read` under `--config` → `Command jobs not found` after N5. [layering-v1](../.archive/briefs/layering-v1.md) |
| N9 | landed | Cut A: `modules/core/*.nu` file units; dataspection façade owns `read`; `par`/`jobs` never import `dataspection/mod.nu`. [layering-v1](../.archive/briefs/layering-v1.md) |
| N10 | landed | `jobs fetch` is the uncapped stored body. `jobs read` no longer has `--full`. Retrieve strings name `jobs fetch <tag>`. |
| N11 | landed | Unbounded `process capture` lives in `core/capture.nu`. Ordinary `xq` is the terminal command; rg consumes capture, not `xq`. [xq-v1](../briefs/xq-v1.md), [rg-wrapper-v1](../briefs/rg-wrapper-v1.md) landed 2026-08-22 |
| N12 | parked | Module prefixing (`nu-` vs bare). [module-prefixing.md](../notes/module-prefixing.md) |
| N13 | carried | Write conventions (state `.nushell-mcp/`, scratch `artifacts/nushell-mcp/`). [write-conventions-v1](../notes/write-conventions-v1.md) |
| N14 | carried | Identity routing one shape `{scope, id, source, via}`. [identity-routing.md](../notes/identity-routing.md), [gh-v1](../briefs/gh-v1.md) |
| N15 | landed | Missing/running/failed/cancelled jobs are stamped `ok: false`, not throws or `null` payloads. Only `completed` yields a body. Retrieve tags are NUON-quoted. Unknown `shape.bytes` is not disclosed (`ok: false`); `jobs fetch` remains the hatch. |

## N9 — layering cut (landed A, 2026-08-22)

`modules/core/` is a loose dir of file units (`census.nu`, `meta.nu`,
`value.nu`, `failure.nu`, `schema.nu`, `spine.nu`, `views.nu`).
`dataspection/mod.nu` re-exports the agent-facing commands and owns
`read`. `par`/`jobs` `use core/census.nu` / `core/meta.nu`.
`capture.nu` waits for xq-v1 (N11). Layout and nits in
[layering-v1](../.archive/briefs/layering-v1.md). Trail:
[sol-nushell-mcp-rearchitect-revisions.md](../.archive/discussion/sol-nushell-mcp-rearchitect-revisions.md).

B (read on jobs), `dataspection-core`, `nushell-mcp-core`, and nested
`core/census/mod.nu` are rejected.
