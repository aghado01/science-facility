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
| N1 | landed | `nu --mcp` is the engine protocol, not the product surface. Thin host later. [session-host-v1](../briefs/session-host-v1.md) |
| N2 | landed | This package designs one MCP user's console plus an embedding surface. Integration is para-agent's. [launch-surface](../notes/launch-surface.md) |
| N3 | landed | Portable verbs (`inspect`, `read`, `preview`, `page`, `stamp`) are meanings. In-hand vs addressed is membership, not a second vocabulary. [vocabulary.md](../notes/vocabulary.md) |
| N4 | landed | One `bytes` definition: NUON UTF-8 length via `shape`. [dataspection-v1](../briefs/dataspection-v1.md) `5381bf3` |
| N5 | landed | `jobs inspect` is not `jobs read \| shape`. Inspect calls `shape` internally. `058f887` |
| N6 | landed | `par cap` is the one inline/query cap resolver. `058f887` |
| N7 | landed | In-hand `read` and `jobs read` share the cap rule. Current retrieve is `jobs read <tag> --full`. `058f887` |
| N8 | landed | Overlay `use *` is not dependency injection into module bodies. Config.nu composes the agent surface. Witness: `$x \| read` under `--config` → `Command jobs not found` after N5. [layering-v1](../briefs/layering-v1.md) |
| N9 | ruled | Cut A: `modules/core/*.nu` file units; dataspection façade owns `read`; `par`/`jobs` never import `dataspection/mod.nu`. [layering-v1](../briefs/layering-v1.md) |
| N10 | **OPEN** | `jobs fetch` (uncapped stored body) vs keeping `--full`. After N9 lands, before xq. |
| N11 | carried | Unbounded `process capture` lives in `core/capture.nu` (xq-v1). Ordinary `xq` is the terminal command; rg consumes capture, not `xq`. [xq-v1](../briefs/xq-v1.md) |
| N12 | parked | Module prefixing (`nu-` vs bare). [module-prefixing.md](../notes/module-prefixing.md) |
| N13 | carried | Write conventions (state `.nushell-mcp/`, scratch `artifacts/nushell-mcp/`). [write-conventions-v1](../notes/write-conventions-v1.md) |
| N14 | carried | Identity routing one shape `{scope, id, source, via}`. [identity-routing.md](../notes/identity-routing.md), [gh-v1](../briefs/gh-v1.md) |

## N9 — layering cut (ruled A, 2026-08-22)

`modules/core/` is a loose dir of file units (`census.nu`, `meta.nu`,
`value.nu`, `failure.nu`, `schema.nu`, `spine.nu`, `views.nu`).
`dataspection/mod.nu` re-exports the agent-facing commands and owns
`read`. `par`/`jobs` `use core/census.nu` / `core/meta.nu`.
`capture.nu` waits for xq-v1 (N11). Layout and nits in
[layering-v1](../briefs/layering-v1.md). Trail:
[sol-nushell-mcp-rearchitect-revisions.md](../discussion/sol-nushell-mcp-rearchitect-revisions.md).

B (read on jobs), `dataspection-core`, `nushell-mcp-core`, and nested
`core/census/mod.nu` are rejected.
