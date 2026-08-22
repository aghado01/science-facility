# Session host v1 — a thin TypeScript MCP host in front of `nu --mcp`

**Status:** filed, not started · **Filed:** 2026-08-21 · **Home:**
`mcp/nushell-mcp/host/` (TypeScript). **Engine:** `nu --mcp --config
config.nu` (pinned `deps/nushell/nu.exe`), unchanged.
**Depends on:** nothing in the Nu modules; they load through `config.nu`
regardless of who speaks JSON-RPC to the engine.
**Not this brief:** replacing `nu --mcp`; any Nu semantics in TS; a web
UI; merging with para-agent (reuse its structures, don't fuse).

Treat this file as the v1 spec. Amend; do not fork.

## Problem (all verified 2026-08-21 against nu 0.114.1 `--mcp`)

- One tool (`evaluate`) plus `command_help`/`list_commands`. No
  resources, no structural reads.
- `$history` entries are **output-only**: no timestamp, no source text.
  `history_index` and `timestamp` exist only in the tool result the
  client sees.
- **Hooks do not fire** under `--mcp` (`pre_execution`,
  `display_output` tested). Nothing can be captured per evaluate
  in-engine.
- Pipeline metadata is stripped on storage (`metadata set` → only
  `span` survives in `$history`).
- Truncation is one env knob (`NU_MCP_OUTPUT_LIMIT`), a blind byte chop.
- No identity, one client, engine dies with the client.

What `nu --mcp` does that nothing else can: a **persistent engine behind
a protocol** — EngineState + Stack alive across calls, JSON-RPC in. That
is the foundation; keep it. The narrowness is the *surface*, and the
surface is cheap to own.

## Architecture

```
agent ──MCP (stdio)──▶ host ──MCP client (stdio)──▶ nu --mcp child (per identity)
                        │
                        ├─ ledger      host-side history index + scoped artifacts
                        ├─ identity    caller → engine child, env injected at spawn
                        └─ policy      cap, informative truncation, retention
```

The host is an MCP server to the agent and an MCP client to one or more
engine children. `nu --mcp` demotes from "the MCP" to "the engine
protocol".

**Thinness rule (enforced by review):** the host never interprets Nu
values beyond a closed set of fields: the engine result's `cwd`,
`history_index`, `timestamp`, `output`/`note`, error records, and — when
present on a record output — `meta.{kind, at, tag, elapsed, ref}` (the
receipt-stamp convention, probe-v1). Everything else is opaque NUON
passed through. Semantics live in Nu modules; the host is transport +
ledger + identity + policy. If a feature needs the host to understand a
Nu value, it is a Nu verb, not a host feature.

## Tool surface

Small, structural, and `evaluate`-compatible so existing skills do not
change.

| Tool | Contract |
|---|---|
| `evaluate {input}` | passthrough to the engine; result relayed verbatim except: on engine truncation the host appends a census (below) |
| `history {since?, kind?, tag?, last?}` | receipt table from the host ledger — `{index, at, ms, source, bytes, ok, kind?, tag?, tags, note}`. Never bodies |
| `read {index, path?, page?, size?}` | one entry or one cell path from `$history`, bounded (`page`/`size` → the engine's `page` verb). One body per call |
| `annotate {index, tags?, note?}` | agent labels on the ledger — the only thing the engine cannot know |
| `console` | one record: engine version, identity, session id, ledger depth, cap, `jobs status` |

Resources: `nu://history/{index}` (= `read`), `nu://history` (= the
receipt table). Optional in v1; the tools are the contract.

No other tools. `par`/`jobs`/`xq`/probe/rg stay Nu verbs through
`evaluate` — the host adds no per-module tools.

## Ledger (the history index, done where the data is)

Every relayed `evaluate` writes one ledger row:

```
{index: int, at: datetime, ms: int, source: string, bytes: int, ok: bool,
 truncated: bool, kind?: string, tag?: string, ref?: record,
 tags: list<string>, note?: string}
```

- `index`/`at` from the engine result; `source` = the `input` the host
  sent; `ms` measured by the host; `bytes` = relayed output length;
  `kind`/`tag`/`ref` lifted from `meta` when the output is a stamped
  record. `tags`/`note` from `annotate`.
- `source` is stored **verbatim** — it is the spine's "what produced
  this". Redaction is policy (below), never default.
- The ledger is the **session history artifact**: persisted as it grows
  (JSONL append), identity-scoped, routed by config:
  `<history_dir>/history-<session_id>-<agent_id>.jsonl`. No generic
  filenames (par-jobs-v1 → Persistence and identity). Standard issue:
  on by default.
- The in-engine `$history` stays the value store; the ledger never
  copies values. `read` goes to the engine. If the engine child dies,
  the ledger survives and rows mark `lost: true` on `read`.

This retires the Nu-side index sidecar sketched for hist-v1: in-engine,
`$history | shape each` (probe) remains the idiom for an agent that
wants census without the host; `stamp` remains the convention that
makes ledger rows rich. Nothing in Nu tracks tags/notes.

## Identity and sessions

- **Caller-routed.** Host config maps a caller (MCP client name, an env
  var, or an explicit `identity` in the launch args) to `{agent_id}`.
  `session_id` is minted by the host per connection unless the caller
  supplies one to resume.
- **One engine child per `(session_id, agent_id)`**, spawned with
  `NU_MCP_SESSION_ID` / `NU_MCP_AGENT_ID` injected (the one deliberate
  extension to the `--config`-only launcher contract). Joint sessions
  stop being a filename problem: each agent has its own engine and its
  own ledger file.
- **Sessions can outlive the client.** The host keeps a child alive for
  `keepalive` (config) after disconnect; a reconnect with the same ids
  resumes `$history`, `$env.JOBS`, running jobs. This is the first slice
  of "jobs that outlive the MCP child" without a daemon.
- Child crash → host respawns on next `evaluate`, ledger intact, prior
  entries `lost`.

## Policy

Config `host.json` next to `config.nu` (single owner of host layout;
`config.nu` stays single owner of engine layout):

```json
{
  "engine": "./deps/nushell/nu.exe",
  "config": "./config.nu",
  "output_limit": "20kb",
  "history_dir": "./.sessions",
  "keepalive": "30min",
  "retention": {"max_files": 50, "max_age": "30d"},
  "identity": {"default_agent": "claude", "from_env": "NU_MCP_AGENT_ID"},
  "redact": []
}
```

- `output_limit` is passed to the child as `NU_MCP_OUTPUT_LIMIT`; the
  engine still truncates. **Informative truncation:** when a relayed
  result is truncated, the host issues one follow-up
  `$history.<index> | shape` to the engine and appends the census to the
  result (`{truncated: true, shape: {...}, hint: "read {index}"}`). The
  agent always learns *what* it has, never just that it was cut.
- `.sessions/` is gitignored. `retention` prunes by count/age — the only
  destructive action the host takes, and only on its own files.
- `redact` is a list of regexes applied to `source` before persistence
  (never to in-memory ledger rows). Empty by default.

## Tree

```
mcp/nushell-mcp/host/
  package.json           # @modelcontextprotocol/sdk, zod, vitest
  host.json              # policy (above)
  src/server.ts          # MCP server: tools, resources
  src/engine.ts          # MCP client to nu --mcp; spawn/respawn/keepalive
  src/ledger.ts          # rows, JSONL append, routing, retention
  src/identity.ts        # caller → ids, env injection
  src/policy.ts          # cap, informative truncation, redact
  test/                  # vitest against a real child (deps/nushell)
.mcp.json                # `nushell` entry → node host/dist/server.js
```

`evaluate`'s description text is copied from the engine's so skills
stay valid; `history`/`read`/`annotate`/`console` get their own.

## Tests (vitest, real engine child)

- `evaluate` relays verbatim: same `history_index`, `timestamp`,
  `output` as a direct `nu --mcp` call
- ledger row per evaluate: `source` verbatim, `at`/`index` match the
  engine, `ms` > 0, `bytes` = output length
- stamped record → row has `kind`/`tag`/`ref`; bare table → row has
  none, no error
- truncated result (cap forced low) → relayed result carries
  `truncated: true` and a `shape` census; one extra engine round-trip,
  not N
- `history` returns receipts only; `last`/`kind`/`tag` filters work;
  never includes output
- `read {index, path}` returns one body; `page`/`size` bound it
- `annotate` persists; appears on `history` and in the JSONL file
- identity: two callers → two children, two ledger files, names carry
  both ids; no generic filename ever written
- keepalive: disconnect, reconnect with same ids within window →
  `$history` length continues; after window → fresh engine, old ledger
  file untouched
- child killed out-of-band → next `evaluate` respawns; old rows `lost`
- retention prunes oldest beyond `max_files`; never touches other dirs

## Exit gate

Agent connects through the host; three `evaluate`s (`jobs spawn { 1..8
| par {|i| $i * $i} } --tag sq`, `jobs collect`, `jobs read sq`) behave
exactly as against bare `nu --mcp`. `history` shows three rows with
`source`, `at`, and `kind: jobs.spawn` on the first. A forced-truncated
fourth evaluate comes back with a `shape` census. A second identity gets
its own engine and ledger file. Kill the host; the JSONL ledgers are on
disk with identity in their names.

## What moves, what stays

| Concern | Before | After |
|---|---|---|
| history index (at, source) | impossible in-engine | host ledger |
| tags / notes | Nu sidecar (hist-v1 sketch) | host `annotate` |
| identity routing | doctrine only | host, env injected |
| scoped history artifact | session layer "later" | host, standard issue |
| informative truncation | per-wrapper (`spine`, `disclose`) | still per-wrapper for *findings*; host adds census for *any* truncated result |
| `par`/`jobs`/`xq`/probe/rg | Nu modules | unchanged |
| receipt `meta` stamps | probe-v1 convention | unchanged; the host reads them |

## Non-goals (v1)

- Replacing or forking `nu --mcp`; driving `nu` via a text REPL/PTY
  (that is para-agent's surface)
- Implementing any Nu verb in TypeScript; parsing NUON beyond the
  closed field set
- Per-module MCP tools (`jobs_*`, `rg_*`, …)
- Cross-engine job tables, shared `$env` between identities
- A true daemon (survives host restart) — keepalive is the v1 slice
- Web UI, dashboards, transcripts beyond the ledger row

---

## Follow-up report

_Chip or implementer: append outcome, tests run, deviations from this spec._
