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
                        ├─ journal     Console Journal Contract v1 stream per engine session
                        ├─ identity    caller → engine child, env injected at spawn
                        └─ policy      cap, informative truncation, retention
```

The host is an MCP server to the agent and an MCP client to one or more
engine children. `nu --mcp` demotes from "the MCP" to "the engine
protocol".

**Thinness rule (enforced by review):** the host never interprets Nu
values beyond a closed set of fields: the engine result's `cwd`,
`history_index`, `timestamp`, `output`/`note`, error records, and — when
present on a record output — `ok` and `meta.{kind, at, tag, elapsed, ref}` (the
receipt-stamp convention, probe-v1). Everything else is opaque NUON
passed through. Semantics live in Nu modules; the host is transport +
ledger + identity + policy. If a feature needs the host to understand a
Nu value, it is a Nu verb, not a host feature.

## Tool surface

Small, structural, and `evaluate`-compatible so existing skills do not
change.

Tool names match para-agent's Console plane so skills and habits
transfer when this host is plugged in as a visitor MCP.

| Tool | Contract |
|---|---|
| `evaluate {input}` | passthrough to the engine; result relayed verbatim except: on engine truncation the host appends a census (Policy) |
| `log {from?, to?, limit?, kind?, tag?}` | journal read → records + **unconditional receipt** (`complete`, `withheld[]`, `deferredBodies[]`, `cursor`). Never bodies beyond `inlineLimit` |
| `body {turn, path?, page?, size?}` | one quarantined payload — from the body file, or live from `$history.<turn>` with a cell path / page when the engine is up. One body per call |
| `find {pattern, kind?, from?}` | search `cmd`/`preview`/`note` text in the journal; receipt as `log` |
| `annotate {turn, tags?, note?}` | appends a `note` record `{turn, data: {tags, note}}` — agent labels, the one thing the engine cannot know |
| `console` | one record: engine version, identity, session id, stream, journal depth, `inlineLimit`, `jobs status` |
| `spawn` / `list` / `kill` | engine lifecycle, para-agent names (see Persistence without a mux). Host-level; the engine cannot list or kill itself |

No other tools. `par`/`jobs`/`xq`/probe/rg stay Nu verbs through
`evaluate` — the host adds no per-module tools.

## Ledger = a Console Journal Contract v1 stream

Do not invent a ledger. para-agent's
`contract/CONSOLE-CONTRACT.md` is a **format-based** contract — any
conforming producer is a valid source — and it already encodes
receipts-not-bodies, bodies-as-files, unconditional receipts, integer
cursors, and no-silent-omission. The host is a **new producer** of
conforming journals; para-agent's reader works over engine streams
with zero code dependency in either direction (its rule: "a plugin is
not a dependency"; ours too). See
[notes/para-agent-archaeology.md](../notes/para-agent-archaeology.md).

Layout, per the contract, one stream per engine session:

```
<root>/streams/<YYYYMMDD_HHmmss>_nu-<agent_id>-<session8>/   # stamp = session start
    journal.jsonl          append-only, seq-ordered — the truth
    journal.idx            writer-maintained offset index (below)
    turns.idx              turn → first seq (+ generation, history_index?)
    turns/000017.out       NUON body, byte-exact, when over inlineLimit
```

**Fast lookup: the offset index.** Every journal record is one
physical line, and the host is the writer, so the byte offset of each
line is known at append time — no scan ever builds this index.

- `journal.idx` is **fixed-width binary**, one entry per `seq`:
  `u64 offset, u32 len` (12 bytes). Because `seq` is dense and
  gap-free (contract), the entry's *position* is the `seq`: lookup is
  `seek(seq * 12)`, read 12 bytes, `seek(offset)`, read `len`. O(1),
  no parsing of anything but the one record wanted. A JSONL index
  would itself need scanning; fixed width is the point.
- `turns.idx` is the same shape over turns: `u32 first_seq, u16
  generation, u32 history_index (0xFFFFFFFF = none)` — the sparse map
  `turn → {generation, history_index?}` from above, persisted, and
  also O(1) by position since `turn` is session-monotonic.
- **Truth is `journal.jsonl`; the indexes are caches.** Written *after*
  the journal line is flushed. On open, the host validates
  `idx.length == seq_count * 12` and that the last entry's
  `offset + len == journal size`; any mismatch → rebuild both indexes
  with one sequential scan (cheap: bodies are external, so the journal
  is small) and emit a `note`. A reader that finds no index, or a
  stale one, scans — it never fails and never trusts a bad index.
- Bodies are already O(1) by construction (`turns/<seq>.out` is the
  path). `cmd_hash`/`out_hash` (contract fields) give cheap identity
  for dedup and recall; a hash → seq map is *not* built in v1 — `find`
  over a small journal is a scan, and that is fine until measured
  otherwise.
- Contract posture: the Console Journal Contract already places
  "reader-side index" outside itself. `journal.idx`/`turns.idx` are
  exactly that — optional, tolerated if absent or stale, never
  required by any reader. Propose upstream as an *optional* layout
  note, not a requirement.

Per relayed `evaluate`, the host writes:

- `turn` — `cmd` = `input` verbatim, `cwd` from the engine result,
  `shell: "nu"`, `origin: "evaluate"`, `cmd_hash`. `turn` is
  **session-monotonic and counts every evaluate**; `history_index` is
  neither. Verified 2026-08-22: `$history` is a bare `list<any>` of
  returned values, **failed evaluates leave no entry** (the error
  result has no `history_index`; the next success takes the next
  slot), a `nothing` result is stored as `[]`, and a respawned engine
  restarts at 0. So the host keeps an explicit sparse map
  `turn → {generation, history_index?}` — no offset arithmetic — and
  records each generation in a `note`. `body`'s live path resolves
  through that map; a failed turn has no live body, only its `exit`
  and whatever `stderr`-like text the error result carried.
- `out` — `bytes`/`lines`/`out_hash` over the NUON output; `text`
  inlined iff `bytes <= inlineLimit`, else `ref` + `preview`.
  `truncatedInline: false`, always.
- `exit` — `ok` from the engine (**engine-level**: did the evaluate
  throw), `code: null` (no process), `duration_ms` host-measured,
  `outcome: completed | died`.
- `note` — engine spawn/respawn/keepalive expiry/lost `$history`;
  `data` carries what is lifted from a record output — the layer's
  `ok` (**domain-level**: a verb caught a failure and returned it as
  data; the evaluate itself succeeded and has a `history_index`) and
  `meta` (`kind`, `tag`, `ref`) — plus `annotate` labels, keyed by
  `turn`. The two `ok`s are different facts and are never merged:
  `exit.ok: true` with `data.ok: false` is the normal signature of a
  caught failure, and `log --kind` / `find` can select on it.

Contract amendments to file against para-agent (additive): `shell`
gains `nu`; `origin` gains `evaluate`. Nothing else.

Consequences:

- The journal **is** the session history artifact — identity in the
  stream name, standard issue, no generic filenames. Big outputs land
  as byte-exact NUON files: the vision's "written to file" for free,
  and they **survive engine death** (`body` serves from the file; a
  dead engine costs only the ability to slice by cell path).
- `$history` stays the in-engine value store for slicing; the journal
  never replaces it, it outlives it.
- The engine has no `.done`/`.cancel` sentinels — JSON-RPC completes
  and `jobs cancel` is in-engine. Producer-side `note` records cover
  what the PTY signals covered.

This retires the Nu-side index sidecar sketched for hist-v1: in-engine,
`$history | shape each` (probe) remains the idiom for an agent that
wants census without the host; `stamp` remains the convention that
makes journal `note` data rich. Nothing in Nu tracks tags/notes.

## Persistence without a mux

para-agent's persistence is a property of the **multiplexer daemon**:
the MCP process is stateless, panes live in psmux, and "a session" is
a named pane an agent returns to. That idea emerged at the interface
between the primary agent and para-agent, and it is pane-shaped.
Muxless does not mean daemonless — it means the persistent thing is an
**engine process** instead of a pane, and something has to own it.

**The host is the mux for engines.** Every structural role psmux plays
for panes, the host plays for `nu --mcp` children:

| psmux (para-agent Console plane) | Session host (nushell-mcp) |
|---|---|
| server daemon (`-L` namespace) | host process (one per `journal_root`) |
| session / pane, by name | engine child, by `(session_id, agent_id)` |
| `spawn` / `list` / `kill` | same verbs, same names, over engines |
| `send-keys` + `capture-pane` | `evaluate` (sync) — values in, values out |
| `run`/`exec` + `.done` sentinel | `evaluate` completes in-protocol; `jobs spawn`/`collect` for async |
| `wait` (stable screen / pattern) | `jobs collect --timeout`; nothing to wait *on* for sync evaluates |
| pane scrollback | `$history` (values) + journal bodies (files) |
| Console Journal stream per pane | Console Journal stream per engine — same contract |
| human `attach` to a pane | **no equivalent in v1** (see below) |
| shared pane (two agents, one shell) | not in v1: one engine per identity; a *shared* engine is an explicit grant, later |

Lifecycle verbs are therefore part of the host surface — `spawn`
(an engine for an identity), `list` (engines, with journal depth and
inflight), `kill` — using para-agent's names so a participant who
knows the Console plane knows this one. They are host-level, not Nu
verbs: the engine cannot list or kill itself.

**Lifetimes, in three steps.** (1) v1: engine lifetime = host lifetime,
plus `keepalive` across client disconnect — already more than a pane
gets from a stateless MCP. (2) v2: the host becomes a daemon and the
MCP stdio process becomes a thin shim connecting to it over a local
socket/named pipe — exactly psmux's server/client split, and the point
at which engines survive client *and* shim restarts. (3) Engine-state
snapshot/restore (`$env` export, registry spill into the stream dir)
for survival across host restarts — daemon-era, not promised.

**What a pane has that an engine lacks — say it plainly:**

- **A screen.** A human can `attach` to a pane and watch. An engine
  has no terminal; a human sees the journal (`log --follow` is the v1
  answer) and may later get a local REPL client that speaks `evaluate`
  to a named engine (`host attach <session>`) — the honest analogue of
  attach, filed as future.
- **Shared state with a human shell.** A nu pane *is* a shell a human
  could also type into. The engine's `$env`, `$history`, `$env.JOBS`
  are reachable only through `evaluate`. Deploying into para-agent
  therefore gives participants two different nu things: panes (text,
  shareable, watchable) and engines (values, per-identity, journaled).
  Both are legitimate; the visitor grant decides which a participant
  gets, and the journal reader does not care.

**Co-design hooks for the para-agent deployment**, recorded now so the
host does not drift from them:

- Stream naming: `nu-<session>-<agent>` lives under the same
  `<root>/streams/` as pane streams. para-agent's `log`/`body`/`find`
  must accept engine stream names; nothing else changes for it.
- A shared engine (if ever granted) needs per-turn attribution the
  contract lacks — a `turn.agent` field. Amendment to file *only* when
  that grant exists; until then one engine per identity keeps `turn`
  = `history_index` exact.
- Mediated turns may `ref` engine turns (`{stream, turn}`) as evidence.
  That is the mediation plane's amendment to make, not the host's.

## Identity and sessions

- **Caller-routed.** Host config maps a caller (MCP client name, an env
  var, or an explicit `identity` in the launch args) to `{agent_id}`.
  `session_id` is minted by the host per connection unless the caller
  supplies one to resume.
- **One engine child per `(session_id, agent_id)`**, spawned with
  `NU_MCP_SESSION_ID` / `NU_MCP_AGENT_ID` injected (the one deliberate
  extension to the `--config`-only launcher contract). Joint sessions
  stop being a filename problem: each agent has its own engine and its
  own journal stream.
- **Sessions can outlive the client.** The host keeps a child alive for
  `keepalive` (config) after disconnect; a reconnect with the same ids
  resumes `$history`, `$env.JOBS`, running jobs. This is the first slice
  of "jobs that outlive the MCP child" without a daemon.
- Child crash → host respawns on next `evaluate`, journal intact; prior
  turns get a `note` (lost `$history`) and `body` serves from files.
- **Governance is not the host's.** Whether a participant may reach
  nushell-mcp is para-agent's visitor-registry question
  (`issues/para-agent/notes/visitor-mcp-registration.md`); the host
  only routes. Posture from para-agent, adopted: **label, don't gate**
  — an unrecognized caller gets the configured default identity plus a
  `note` saying so, never a refusal.
- Identities are validated as well-formed Unicode scalar sequences
  before they touch a stream name (para-agent `identity.js` rule), so
  two logical identities cannot collide through replacement characters.

## Policy

Config `host.json` next to `config.nu` (single owner of host layout;
`config.nu` stays single owner of engine layout):

```json
{
  "engine": "./deps/nushell/nu.exe",
  "config": "./config.nu",
  "output_limit": "20kb",
  "journal_root": "./.nushell-mcp/journals",
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
- `.nushell-mcp/` is gitignored (`**/.nushell-mcp/**`). Roots and precedence: [write-conventions-v1](write-conventions-v1.md). `retention` prunes by count/age — the only
  destructive action the host takes, and only on its own files.
- `redact` is a list of regexes applied to `source` before persistence
  (never to in-memory records). Empty by default.

## Tree

```
mcp/nushell-mcp/host/
  package.json           # @modelcontextprotocol/sdk, zod, vitest
  host.json              # policy (above)
  src/server.ts          # MCP server: tools, resources
  src/engine.ts          # MCP client to nu --mcp; spawn/respawn/keepalive
  src/journal.ts         # Console Journal v1 producer + minimal reader, routing, retention
  src/identity.ts        # caller → ids, env injection
  src/policy.ts          # cap, informative truncation, redact
  test/                  # vitest against a real child (deps/nushell)
.mcp.json                # `nushell` entry → node host/dist/server.js
```

`evaluate`'s description text is copied from the engine's so skills
stay valid; `log`/`body`/`find`/`annotate`/`console` get their own.

## Tests (vitest, real engine child)

- `evaluate` relays verbatim: same `history_index`, `timestamp`,
  `output` as a direct `nu --mcp` call
- turn/out/exit records per evaluate: `cmd` verbatim, `turn` session-monotonic (a failed evaluate still gets a turn, with no `history_index`), `ts` match the
  engine, `ms` > 0, `bytes` = output length
- stamped record → row has `kind`/`tag`/`ref`; bare table → row has
  none, no error
- truncated result (cap forced low) → relayed result carries
  `truncated: true` and a `shape` census; one extra engine round-trip,
  not N
- `log` returns records + unconditional receipt (`complete`, `withheld` naming retrieval); `kind`/`tag` filters work;
  never includes output
- `body {turn, path}` returns one body (file or live); `page`/`size` bound it
- `annotate` persists; appears as a `note` record on `log` and in journal.jsonl
- identity: two callers → two children, two journal streams, names carry
  both ids; no generic filename ever written
- keepalive: disconnect, reconnect with same ids within window →
  `$history` length continues; after window → fresh engine, old journal
  file untouched
- child killed out-of-band → next `evaluate` respawns; a `note` records the loss; `body` still serves from files
- retention prunes oldest beyond `max_files`; never touches other dirs
- offset index: `journal.idx` entry `seq` resolves to exactly that line
  (seek, no scan); `turns.idx` resolves `turn` → `{generation,
  history_index?}`; a failed turn has `history_index: none`
- index validation: truncate `journal.idx` by 12 bytes → host rebuilds
  both indexes on open, emits a `note`, results identical; delete the
  indexes → reader scans, no error; indexes always written after the
  journal line

## Exit gate

Agent connects through the host; three `evaluate`s (`jobs spawn { 1..8
| par {|i| $i * $i} } --tag sq`, `jobs collect`, `jobs read sq`) behave
exactly as against bare `nu --mcp`. `log` shows three turns with
`source`, `at`, and `kind: jobs.spawn` on the first. A forced-truncated
fourth evaluate comes back with a `shape` census. A second identity gets
its own engine and journal stream. Kill the host; the journals are on
disk with identity in their names.

## What moves, what stays

| Concern | Before | After |
|---|---|---|
| history index (at, source) | impossible in-engine | host journal (Console Journal v1) |
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
- Web UI, dashboards, transcripts beyond journal records

---

## Follow-up report

_Chip or implementer: append outcome, tests run, deviations from this spec._
