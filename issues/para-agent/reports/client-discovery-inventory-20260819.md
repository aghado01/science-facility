# Client discovery inventory — 2026-08-19

- **Scope:** this machine, this repository (`D:\aghado01\science-facility`), the four installed
  primary-agent CLIs plus one installed-config-only vendor.
- **Method:** configuration-file reads and static introspection (`grok inspect --json`,
  `grok mcp doctor --json`). No model call, no authenticated turn, no session artifact.
- **Standing:** point-in-time. This is a *census*, not a contract. It ages the moment any vendor
  changes a discovery default.
- **Why:** [client-asset-provenance](../notes/client-asset-provenance.md) (P21) — knowing what
  each client reaches for is the precondition for declaring it.

## Installed

| Client | Version | Config home(s) | Trust store | Repo `.mcp.json`? |
|---|---|---|---|---|
| Claude Code | `2.1.233` | `~/.claude/`, `~/.claude.json` | `~/.claude.json` → `hasTrustDialogAccepted` | **yes** |
| Grok Build | `1.0.4 (d846eb93d9)` | `~/.grok/` | `~/.grok/trusted_folders.toml` | **yes** (folder-trust gated) |
| Codex CLI | `0.147.0` | `~/.codex/config.toml` | `~/.codex/config.toml` → `[projects.*] trust_level` | not observed |
| AGY (Antigravity) | `1.1.13` | `~/.antigravity-ide/`, `%LOCALAPPDATA%\agy`, `%LOCALAPPDATA%\antigravity`, `%APPDATA%\Antigravity`, `%APPDATA%\Antigravity IDE`, `~/.agents` (empty) | none found | no MCP surface found |
| Cursor | CLI not installed | `~/.cursor/` — `mcp.json`, `hooks.json`, `skills-cursor/`, `agents/`, `plugins/` | — | — |

This repository is trusted in **three** separate stores with three different spellings, and the
decisions are independent of one another.

## Per client — what it reaches for

### Claude Code 2.1.233

| Surface | Source | State in this repo |
|---|---|---|
| MCP, personal | `~/.claude.json` → `mcpServers` | `git`, `fetch`, `filesystem`, `pwsh_exec` |
| MCP, repo | `.mcp.json` | `para-agent`, `pwsh_exec`, `nushell` |
| MCP enablement | `~/.claude/settings.json` → `enabledMcpjsonServers` | `["para-agent","pwsh_exec","nushell"]` — **user scope, not project scope** |
| Instructions | `~/.claude/CLAUDE.md`, memory index, project `CLAUDE.md` | global file + `MEMORY.md` loaded; **no project instruction file loaded** |
| Skills | `~/.claude/skills/` (2), plugin/marketplace skills | `chat-export`, `nushell-mcp` + plugin-supplied |
| Hooks | `~/.claude/settings.json`, project `.claude/settings.json` | none declared at either level |

Two things stand out.

**Enablement is declared at user scope.** `enabledMcpjsonServers` lives in
`~/.claude/settings.json` and names `para-agent`, `pwsh_exec`, `nushell` — repo-owned server
*names*, pre-approved globally. Any other repository whose `.mcp.json` declares a server by one of
those names is enabled without a prompt. The per-project entries in `~/.claude.json` carry empty
`enabledMcpjsonServers` arrays, so the user-scope list is doing all the work.

**The repo's instruction file is invisible to it.** This repository's instruction file is
`AGENTS.md` (git-tracked, uppercase; Windows case-insensitivity is why `Agents.md` also resolves).
Grok loads it as project instructions. This Claude session's context contains
`~/.claude/CLAUDE.md` and `MEMORY.md` and **no project file** — direct first-person evidence that
the repo's own instructions did not reach the primary agent that does most of the work here.

### Grok Build 1.0.4

Config `~/.grok/config.toml` was edited on 2026-08-19 to set every compat cell false for all three
vendors — `skills`, `rules`, `agents`, `mcps`, `hooks`, `sessions` × `cursor`, `claude`, `codex`.

`grok inspect --json` at this repo cwd, after that edit:

| Surface | Resolved |
|---|---|
| MCP | `para-agent`, `nushell` from repo `.mcp.json`; `git`/`fetch`/`filesystem`/`pwsh_exec` present but `compatibilityStatus: "disabled"` |
| Instructions | repo `AGENTS.md`; `~/.claude\CLAUDE.md` `disabled` |
| Skills | 22 bundled; the 2 `~/.claude/skills/` entries `disabled` |
| Hooks / plugins / marketplaces | 0 / 0 / 0 |

Before the edit it resolved this repository's `pwsh_exec` **from `~/.claude.json`** rather than
from `.mcp.json` — documented merge priority is `config.toml > Claude > Cursor > .mcp.json`, so
repo-owned config was the lowest authority and the name collision resolved against the repository
silently. The compat edit removes the collision by removing the competitor.

Grok is currently the only client here that can *report* its own resolution. `grok inspect --json`
gives source, vendor, and enable-state per asset; nothing else in the fleet has an equivalent.

### Codex CLI 0.147.0

`~/.codex/config.toml`:

| Surface | Declared |
|---|---|
| MCP, personal | `filesystem`, `fetch`, `git`, `node_repl` (the last is Codex's own runtime, `%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\...`) |
| Marketplaces | `openai-bundled`, `openai-primary-runtime` |
| Plugins | 9 declared — but `[features] plugins = false` |
| Trust | `[projects.'d:\aghado01\science-facility'] trust_level = "trusted"` |
| Shell policy | `[shell_environment_policy] inherit = "all"` |
| Instructions | `AGENTS.md` convention |

No repo-level `.mcp.json` discovery was observed, and Codex exposes no `inspect` equivalent to
confirm either way — **unverified, not disproven**.

### AGY 1.1.13

CLI surface has `agent`/`agents`, `models`, `plugin`/`plugins`, `install`, `update`, `changelog` —
**no `mcp` subcommand**. A bounded depth-4 search across all five candidate config homes found no
file matching `*mcp*`. `~/.agents` is empty. No MCP surface for AGY is discoverable on this machine.
Consistent with P12 holding it fail-closed.

### Cursor (config present, CLI absent)

`~/.cursor/mcp.json` declares `filesystem`, `fetch`, `git`, `pwsh_exec` — a fourth copy of the same
set. Also present: `hooks.json`, `skills-cursor/`, `agents/`, `plugins/`, `projects/`. No Cursor CLI
is installed, so nothing here runs Cursor's own agent — but the files are a **live discovery target
for any client with cursor compatibility on**, which Grok had until today.

## Cross-cutting findings

**1. The same four servers are declared four times, in four hands.**

| Server | `~/.claude.json` | `~/.cursor/mcp.json` | `~/.codex/config.toml` | repo `.mcp.json` |
|---|:---:|:---:|:---:|:---:|
| `filesystem` | ✓ | ✓ | ✓ | — |
| `fetch` | ✓ | ✓ | ✓ | — |
| `git` | ✓ | ✓ | ✓ | — |
| `pwsh_exec` | ✓ (abs paths) | ✓ (abs paths) | — | ✓ (repo-relative) |
| `node_repl` | — | — | ✓ | — |
| `para-agent`, `nushell` | — | — | — | ✓ |

`pwsh_exec` exists in three declarations pointing at one server. The repo's copy now uses
repo-relative paths; the two personal copies hard-code `D:/aghado01/science-facility/...`. Drift
between them is silent, and which one a given client runs depends on that client's merge order.

**2. Trust is three stores with no shared vocabulary.** `hasTrustDialogAccepted` (bool, per project,
inside a 57 KB JSON blob), `trusted_folders.toml` (`trusted` + `decided_at`, cascading to
subdirectories, covering MCP + LSP + hooks together), `[projects.*] trust_level = "trusted"`. All
three currently say yes for this repository, decided at three different times for three different
reasons.

**3. Repo-owned config ranks lowest wherever a merge exists.** Demonstrated for Grok. Unknown for
Claude, which has the same `pwsh_exec` collision live right now and no way to report which
definition it resolved.

**4. A vendor-named directory in this repo holds non-vendor artifacts.** `.codex/` contains
`agy-native-stream-capture/`, `agy-native-stream-probe.mjs`, `chat-export/`, `doc-dive/`,
`doc-dive-vscodepilot/` — para-agent evidence and tooling output, not Codex configuration. Nothing
reads it as Codex config today, but the name asserts an ownership that isn't true.

## Proof limits

Everything here is what the configuration layer *declares* or *resolves to*. No client was observed
at runtime enumerating its actual instruction, skill, or tool surface. Specifically:

- `grok mcp doctor` starts servers regardless of the compat gate and is **not** a load witness.
- Claude's resolution of the `pwsh_exec` collision is unobserved.
- Codex's repo-level MCP behavior is unobserved.
- AGY's absence of an MCP surface is an absence of evidence from a bounded search, not proof.

## What this suggests for the substrate

The inventory is the artifact P21 needs and cannot yet produce automatically. Three properties it
argues for, in the order the evidence supports them:

1. **Declared inheritance beats vendor defaults.** Grok took one config edit to go from four
   foreign servers, foreign instructions, and foreign skills down to repo-owned assets only. That
   was possible because Grok exposes the switches *and* reports the result. The other three expose
   neither uniformly.
2. **Ownership belongs in the receipt.** Every collision above is invisible at use time. An
   invocation receipt that names the source of each resolved asset makes drift detectable instead
   of archaeological.
3. **One trust decision, recorded once.** Three stores answering the same question independently is
   how a repository ends up trusted somewhere the operator has forgotten about.
