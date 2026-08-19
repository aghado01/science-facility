# Client asset provenance

- **Written:** 2026-08-19
- **Status:** argument + evidence; no ruling. Feeds the client-setup substrate.
- **Companion evidence:** [grok-1.0.4-wave0-evidence.md § Addendum](../reports/grok-1.0.4-wave0-evidence.md#addendum--2026-08-19-re-probe)
- **Fleet census:** [client-discovery-inventory-20260819.md](../reports/client-discovery-inventory-20260819.md)
  — all four installed clients plus Cursor's orphaned config, and what each reaches for
- **Since written:** `~/.grok/config.toml` now sets every compat cell false for cursor/claude/codex
  (2026-08-19), which removes the §1 shadowing on Grok. The other three clients are unchanged.

## The claim

Every configuration asset this repository exposes to an agent — MCP server, instruction
file, skill, hook, trust decision — has an **owner**, and the owner is one of exactly three
things: the repository, a specific vendor's personal scope, or a specific vendor's install.
Nothing here is "Claude's" merely because Claude is the only primary agent that has consumed
it so far. `science-facility/.mcp.json` is repo-owned. `~/.claude.json` is Claude-personal.
`~/.grok/config.toml` is Grok-personal.

The reason this needs saying is that the clients do not agree on that boundary, and one of
them silently resolves across it.

## Evidence — Grok 1.0.4 at this repo cwd, 2026-08-19

Configuration-layer resolution only; no model call. Full probe record in the companion report.

### 1. Repo-owned config is shadowed by vendor-personal config

`.mcp.json` declares **three** servers: `para-agent`, `pwsh_exec`, `nushell`.
`grok mcp doctor --json` reports `.mcp.json` with `server_count: 2`, and `grok inspect --json`
resolves `pwsh_exec` with `source.type: claudeJson`, `path: ~/.claude.json`, `vendor: claude`.

The repo's own declaration of `pwsh_exec` — with the repo's own target and env — lost to a
same-named entry in Claude's personal scope. Grok's documented merge priority is
`config.toml > Claude > Cursor > .mcp.json`, so **repo-owned MCP config is the lowest
authority in the merge**, and a name collision resolves against the repository silently. No
warning is emitted; the entry simply reports a different source.

This is the sharpest form of the problem: the repository cannot currently guarantee that the
server it declared is the server that runs.

### 2. Instruction provenance crosses vendors by default

`grok inspect --json → projectInstructions` at this cwd:

| path | scope | vendor | status |
|---|---|---|---|
| `C:\Users\azrie\.claude\Claude.md` | global | `claude` | `enabled` |
| `D:\aghado01\science-facility\Agents.md` | project | — | — |

Grok reads the user's **global Claude instructions** as its own. That file carries
Claude-specific doctrine — `defaultShell` is bash, the sub-agent dispatch policy, Claude skill
search paths, the pwsh_exec MCP note. Applied to Grok it is not merely inert, it is wrong:
it describes a harness Grok does not have.

### 3. Skill provenance likewise

`~/.claude/skills/chat-export` and `~/.claude/skills/nushell-mcp` enumerate in Grok's skill
list as user-scope skills with `vendor: claude`, ranked alongside Grok's bundled skills.

### 4. Trust is per-vendor, and the stores disagree

| client | trust store | this repo |
|---|---|---|
| Claude Code | `~/.claude.json` → `hasTrustDialogAccepted` | `true` (accepted earlier) |
| Grok 1.0.4 | `~/.grok/trusted_folders.toml` | granted 2026-08-19 (`decided_at 1787249727`) |

Two stores, two independent decisions, no shared vocabulary. Grok's grant is folder-wide and
cascades to subdirectories, covering MCP, LSP, **and hooks** together — one decision, three
surfaces.

### 5. What the trust grant did *not* activate here

This repo has no `.claude/settings.json`, no `.cursor/`, no `.grok/` — only `.claude/doc-dive/`.
So the 2026-08-19 grant switched on the two `.mcp.json` servers and nothing else. The hook
exposure is a **forward hazard**: the day a project-scope hook file appears under any vendor
directory, it becomes live for Grok under the existing grant, with no second decision.

## Why this belongs to the client-setup substrate

The five-axis decomposition (P5) already separates surface policy, shell profile, application
adapter, host environment binding, and invocation receipt. None of those axes currently says
**which configuration sources a launched client is permitted to resolve, and who owns each
one**. Today that is decided by the client's own discovery defaults, off-repo, per vendor.

Three properties worth designing toward:

1. **Declared inheritance.** A launch descriptor states the sources the client may read —
   vendor-personal, repo, install — rather than inheriting whatever the vendor scans by default.
2. **No silent shadowing.** A repo-owned declaration is never overridden by a vendor-personal
   entry of the same name without that being visible in the receipt.
3. **Ownership is recorded, not inferred.** An asset consumed by an agent carries its owner in
   the invocation receipt, so "who does this belong to" is answerable after the fact.

The isolation controls found on 2026-08-19 (`[compat.<vendor>] mcps = false`,
`GROK_CLAUDE_MCPS_ENABLED`, `GROK_CURSOR_MCPS_ENABLED`, folder trust as default-deny) are the
mechanism for (1) on this one client. They are not a design — they are one vendor's switches,
and the substrate is what makes the intent portable across the five.

## Proof limits

Everything above is what the configuration layer *resolves to*, read from `grok inspect --json`
and `grok mcp doctor --json`. No live session has been observed enumerating its actual
instruction, skill, or tool surface. `grok mcp doctor` in particular is **not** a load witness:
it starts servers regardless of the compat gate. See the companion report.
