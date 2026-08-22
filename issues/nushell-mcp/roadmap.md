# nushell-mcp roadmap

**Status:** living doc — amend in place, newest thinking wins ·
**Started:** 2026-08-21 · **Home:** `mcp/nushell-mcp` (implementation),
this folder (specs).

## North star

An **augmented interactive console experience** on a persistent Nu
session — not a compute platform. It maintains strict context hygiene,
encourages planning and thoughtful execution, and treats the agent's
context window as the scarcest resource in the loop:

- **Non-blocking operations** — slow work runs while the agent keeps
  thinking; the console never holds `evaluate` hostage.
- **Payload quarantine** — big results are written to file or held in
  engine memory and *queried as results*, never dumped into context.
  Always say it with the qualifier: para-agent's mediation plane has
  **commit quarantine** (ambiguous-commit evidence), a different thing
  — see [notes/para-agent-archaeology.md](notes/para-agent-archaeology.md).
  The Console Journal Contract's four design priorities are ours, in
  its order: **no silent omission** (anything withheld names the call
  that retrieves it), **token economy** (the default read is a
  summary), **selectivity**, **facility** ("what happened since I last
  looked" is one call).
- **Skeletal metadata first** — receipts, census, and spine views expose
  the shape of a dataset so retrieval can be surgical and responsible.

## Doctrine (settled)

- **Interactive fan-out over batch compute.** Parallel search inside a
  session is the design center; dataset processing is secondary,
  big-data ergonomics deferred. Ambiguous calls favor the console.
- **Non-blocking + payload quarantine is the product; parallelism is
  a feature.** A single `jobs spawn` at parallelism 1 is a design-center
  use, not a degenerate case.
- **Division of labor:** `rg` owns textual search throughput (internally
  parallel — never sharded through `par` for speed); `par` owns
  structural per-item predicates. `rg` finds *where*, `par` judges
  *what*.
- **Durable primitives**, use-case-agnostic: budgeted dispatch,
  receipts-before-bodies, registry-as-queryable-store. Parallel
  completion is not parallel disclosure.
- **Contracts are documented, not encoded.** Verbs name the dispatch;
  shapes and error stances live in docstrings, the reference corpus, and
  `nu-modules` inspection — never in the handle.
- **Persistence and identity:** the MCP writes no generic filenames;
  identity is **routed by the caller** at spawn (launcher contract =
  `--config` + identity); scoped session history is **standard issue**
  for a persistent session, other historical stores opt-in. Full text in
  [par-jobs-v1](.archive/par-jobs-v1.md) → Persistence and identity.
- **Inherit from the process; do not look up in the environment.** The
  layer takes what it can from the running process — `$nu.current-exe`
  for the engine binary, `path self` for layout, `$nu.os-info` for the
  OS — and reads only a small, audited **launch surface** from its
  host. Ambient lookups are what break when a component moves hosts;
  this is what lets para-agent's engine choice propagate for free
  without nushell-mcp ever naming `PARA_NU_BIN`.
  [notes/launch-surface.md](notes/launch-surface.md).
- **Identity routing is one shape.** Resolved from context by a pure
  router, injected per process; registry external and declarative; no
  global mutation; unknown context labeled, not refused; governance
  separate from routing. Console identity (caller → engine env) and
  GitHub identity (gitdir → `GH_TOKEN`) are two bindings of it, sharing
  the identity receipt `{scope, id, source, via}` — shape, not code.
  [notes/identity-routing.md](notes/identity-routing.md).
- **`nu --mcp` is the engine protocol, not the product surface**
  (decided 2026-08-21). It uniquely provides a persistent engine behind
  JSON-RPC — keep it. Its surface is narrow (verified: one tool,
  output-only `$history`, hooks never fire, metadata stripped), so a
  **thin TypeScript host** fronts it: transport, ledger, identity,
  policy. Thinness rule: the host never implements Nu semantics; if a
  feature needs the host to understand a Nu value, it is a Nu verb.
  The agent's experience stays pure Nushell. See
  [session-host-v1](briefs/session-host-v1.md).
- **Receipts carry provenance by convention.** Every record the layer
  returns has a closed `meta` sub-record (`verb, at, tag?, elapsed?,
  ref?`) via one pure `stamp` primitive; tables stay bare. `$history`
  is a spine of values + positions; `meta` is how entries describe
  themselves and point at each other. (inspect-v1 `stamp`.)

## Sequence

1. **`par` / `jobs` v1** — [par-jobs-v1](.archive/par-jobs-v1.md)
   · landed 2026-08-21. Data plane + handle plane + budget on the
   persistent engine. Carries the envelope contract (shape 4) and the
   registry mechanics.
2. **inspect v1** — [briefs/inspect-v1.md](briefs/inspect-v1.md) · filed (supersedes
   [hist-v1](.archive/hist-v1.md)). Pure primitives, one module:
   `shape` (+ `each`), `schema` (+ `diff`/`check`/`stats`), `spine`,
   `page`, `preview`, `stamp`. jso-jackson's controlled-exploration
   doctrine in Nu's data orientation; the `bytes` definition lives here
   once. No deps — can land in parallel with H. **Next to build.**
3. **par-jobs amendments** — to scribe, before 4: `jobs disclose`
   (value → inline under cap, else `stash` + `tag`; the one cap rule
   `emit`/`xq`/rg all consume — today it is split across `stash` and a
   private cap resolver); receipts gain `meta` via `stamp`
   (spawn/inspect/status/cancel records; tests change); `jobs inspect`
   calls `shape`. Small, but landed code changes, so an amendment with
   its own follow-up entry.
4. **`xq` v1** — [briefs/xq-v1.md](briefs/xq-v1.md) · filed; depends
   on 1–3. Execute, capture, payload-quarantine for every external:
   `complete` + census + `jobs disclose`, job-aware via `job id`. The
   primitive the rg module is a special case of — build before 5.
5. **`rg` module v1** — [briefs/rg-wrapper-v1.md](briefs/rg-wrapper-v1.md)
   · filed, not started; depends on 1, 4. `xq` + JSON-event parse +
   `spine`; `--wrapped` query side. (The module; ripgrep itself is in
   `deps/cli`.)
6. **Query tools on the envelope** — mdnav_v2 chunk shards, `nu-skills
   search` fan-out. First real parallelism consumers. Align the chunk
   shape with mdnav_v2's brief rather than inventing twice.
7. **Host v2: daemon + shim; snapshot/restore** — later. The host
   becomes a daemon, the stdio MCP process a thin shim over a local
   socket (psmux's server/client split); engines survive client and
   shim restarts; jobs outlive the client for real. Engine-state
   snapshot into the stream dir is the step after.
8. **para-agent deployment** — later; its own brief, co-designed.
   nushell-mcp as a visitor MCP: writes under the `.para-agent-mcp/`
   umbrella with conventions modified in that context (open — see
   [write-conventions-v1](notes/write-conventions-v1.md)); roots and
   identity routed at spawn; Console Journal amendments `shell: nu`,
   `origin: evaluate`; retire para-agent's `nu.js` one-shot;
   `turn.agent` only if a shared engine is ever granted. Contract with
   the host is [notes/launch-surface.md](notes/launch-surface.md) —
   engine binary inherited (so `PARA_NU_BIN` needs no mention), plus
   its four hazards: spawn **cwd decides GitHub identity**, engine
   version skew, two `deps` trees on PATH, and the launcher owning
   `NU_MCP_OUTPUT_LIMIT`.

**H. Session host v1** — [briefs/session-host-v1.md](briefs/session-host-v1.md)
· filed. Parallel track, can start now: thin TS MCP host in front of
`nu --mcp` — a **Console Journal Contract v1 producer** (one stream
per engine session, `turn` session-monotonic across engine
generations, NUON bodies as files that survive engine death); tools
`log`/`body`/`find`/`annotate`/`console` + `spawn`/`list`/`kill` with
para-agent's names; caller-routed identity, one engine per `(session,
agent)`, keepalive; informative truncation (one follow-up `shape`);
writes per [write-conventions-v1](notes/write-conventions-v1.md).
Archaeology in [notes](notes/para-agent-archaeology.md). Absorbed the
session-layer history work; 7 keeps only what needs a daemon.

Package rules (landing obligations, closed shapes, write conventions,
vocabulary) live in
[`mcp/nushell-mcp/AGENTS.md`](../../mcp/nushell-mcp/AGENTS.md), not
here. Term senses — whose word is whose — are in
[notes/vocabulary.md](notes/vocabulary.md).

## Briefs

| Brief | Status |
|---|---|
| [par-jobs-v1](.archive/par-jobs-v1.md) | landed 2026-08-21 |
| [inspect-v1](briefs/inspect-v1.md) | filed, not started; no deps; **next to build** |
| [hist-v1](.archive/hist-v1.md) | superseded → inspect-v1 (primitives) + session-host-v1 (index) |
| [session-host-v1](briefs/session-host-v1.md) | filed, not started; parallel track |
| [xq-v1](briefs/xq-v1.md) | filed, not started; depends on par-jobs-v1 + `jobs disclose` amendment |
| [rg-wrapper-v1](briefs/rg-wrapper-v1.md) | filed, not started; depends on par-jobs-v1, xq-v1 |
| [write-conventions-v1](notes/write-conventions-v1.md) | filed; governs every write (state vs scratch, locality, chronology, precedence) |
| [gh-v1](briefs/gh-v1.md) | filed, not started; depends on xq-v1; needs `gh` ≥ 2.40 in `deps/cli` |
