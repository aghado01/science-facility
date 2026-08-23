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
| N9 | **OPEN** | How to cut census from quarantine so `par`/`jobs` never import `dataspection/mod.nu`. [layering-v1](../briefs/layering-v1.md) A vs B. Discussion has proposed **A** with `modules/core/*.nu` units — not ruled. |
| N10 | **OPEN** | `jobs fetch` (uncapped stored body) vs keeping `--full`. Orthogonal to N9. If adopted, separate pointed change after N9, before xq. |
| N11 | **OPEN** | `xq` terminal vs unbounded `process capture` in `core/capture.nu` (rg consumes capture, not ordinary `xq`). Amends xq/rg/gh briefs if ruled. |
| N12 | parked | Module prefixing (`nu-` vs bare). [module-prefixing.md](../notes/module-prefixing.md) |
| N13 | carried | Write conventions (state `.nushell-mcp/`, scratch `artifacts/nushell-mcp/`). [write-conventions-v1](../notes/write-conventions-v1.md) |
| N14 | carried | Identity routing one shape `{scope, id, source, via}`. [identity-routing.md](../notes/identity-routing.md), [gh-v1](../briefs/gh-v1.md) |

## N9 — layering cut (open)

**Problem (settled):** `use dataspection [shape]` loads all of `mod.nu`,
so `par` compiles `read` before `jobs` exists. Child `nu -n` tests do
not see it.

**Rule (settled, in the brief):** a module the handle plane imports must
not import the handle plane.

**Not settled:** A (sibling core, dataspection façade owns `read`) vs B
(`read` moves onto jobs). Discussion trail:

- [sol-circularity-remediation.md](../discussion/sol-circularity-remediation.md) — A, named `dataspection-core`; terminal vs library; `xq capture`
- [grok-nushell-mcp-rearchitect.md](../discussion/grok-nushell-mcp-rearchitect.md) — `core/` folder, not `nushell-mcp-core`
- [sol-nushell-mcp-rearchitect-revisions.md](../discussion/sol-nushell-mcp-rearchitect-revisions.md) — `core/*.nu` file units (`census`, `meta`, `value`, `failure`, …) matching `nu-modules` discovery

**Recommendation on file shape (not a ruling):** do **not** archive
layering-v1. Amend it in place: freeze A, drop B, cite the `core/*.nu`
layout, keep fetch as N10. A superseding brief would fork the problem
statement that is still correct.

Rejected (in the brief, not yet an N-row): circular `use`, env hooks,
copying NUON, a module named `read`, `nushell-mcp-core` as one bag,
dropping `jobs read` in favour of only `fetch`.
