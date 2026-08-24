# nushell-mcp roadmap

**Status:** living doc — amend in place, newest thinking wins ·
**Started:** 2026-08-21 · **Home:** `mcp/nushell-mcp` (implementation),
this folder (specs). **Rulings:** [planning/decisions.md](planning/decisions.md)
· **Done:** [planning/ledger.md](planning/ledger.md).

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
  [par-jobs-v1](.archive/briefs/par-jobs-v1.md) → Persistence and identity.
- **Inherit from the process; do not look up in the environment.** The
  layer takes what it can from the running process — `$nu.current-exe`
  for the engine binary, `path self` for layout, `$nu.os-info` for the
  OS — and reads only a small, audited **launch surface** from its
  host. Ambient lookups are what break when a component moves hosts.
  [notes/launch-surface.md](notes/launch-surface.md).
- **A console, not a requirement** (owner, 2026-08-22). para-agent's
  *backend* nu is a requirement there (`nu.js`, pane dialect, its own
  `deps/bin/nu`); this layer is a **nice-to-have console**, one option
  a participant may be configured with — the two nu dependencies are
  decoupled and separately versioned. Consequences: stand-alone
  usefulness is the priority, integration is not a design driver,
  nothing here may require para-agent, and the visitor grant stays
  optional in both directions.
- **Scope split — what this repo designs, and what it does not**
  (owner, 2026-08-22). nushell-mcp designs **one MCP user's console
  experience**, plus its own *embedding surface* — the audited list of
  what a host may vary ([launch-surface](notes/launch-surface.md)).
  That is why isolation is the default (an engine per identity) rather
  than sharing: the unit of design is one user's console, and several
  of them are isolated instances, not a shared platform.
  It does **not** design the integration. Exposing enough TypeScript
  mediation and abstraction to accommodate either a nushell-mcp-equipped
  client or a bare console — and being intrinsically extensible enough
  to do so — is **para-agent's** responsibility and its extensibility
  problem. Step 8 is deliberately nebulous; do not resolve it from this
  side. Console-integration design belongs in `issues/para-agent/`, not
  here.
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
- **Receipts carry provenance by convention.** Terminal receipts and
  envelopes carry a closed `meta` sub-record
  (`verb, at, tag?, elapsed?, ref?`) via one pure `stamp` primitive;
  arbitrary payload records and tables stay bare. `$history` is a
  spine of values + positions; `meta` is how stamped outcomes describe
  themselves and point at each other. `meta stamp` lives in
  [dataspection](.archive/briefs/dataspection-v1.md) — metadata is data, a
  different tier not a different kind — and takes a noun domain
  because the verb is portable: a timestamp module would have its own.

## Sequence

1. **`par` / `jobs` v1** — [par-jobs-v1](.archive/briefs/par-jobs-v1.md) · **landed** 2026-08-21.
2. **dataspection v1** — [dataspection-v1](.archive/briefs/dataspection-v1.md) · **landed** 2026-08-22 (supersedes [hist-v1](.archive/briefs/hist-v1.md)).
3. **par-jobs amendments** — [par-jobs-v1](.archive/briefs/par-jobs-v1.md) · **landed** 2026-08-22 (after 2, before 4; `jobs fetch`, `meta stamp`, `par cap`).
3b. **layering v1** — [layering-v1](.archive/briefs/layering-v1.md) · **landed** 2026-08-22 (A).
4. **`xq` v1** — [briefs/xq-v1.md](briefs/xq-v1.md) · **landed** 2026-08-22.
5. **`rg` module v1** — [briefs/rg-wrapper-v1.md](briefs/rg-wrapper-v1.md) · **landed** 2026-08-22.
5a. **result composition hardening** — [briefs/composition-v1.md](briefs/composition-v1.md) · **landed** 2026-08-23.
6. **Query tools on the envelope** — mdnav_v2 chunk shards, `nu-skills
   search` fan-out. First real parallelism consumers. Align the chunk
   shape with mdnav_v2's brief rather than inventing twice.
7. **Host v2: daemon + shim; snapshot/restore** — later. The host
   becomes a daemon, the stdio MCP process a thin shim over a local
   socket (psmux's server/client split); engines survive client and
   shim restarts; jobs outlive the client for real. Engine-state
   snapshot into the stream dir is the step after.
8. **para-agent deployment** — later; **nebulous on purpose**, and
   para-agent's to shape (see the scope split above). Listed here only
   so this side knows what it would owe.
   nushell-mcp as a visitor MCP: writes under the `.para-agent-mcp/`
   umbrella with conventions modified in that context (open — see
   [write-conventions-v1](notes/write-conventions-v1.md)); roots and
   identity routed at spawn; Console Journal amendments `shell: nu`,
   `origin: evaluate`; `turn.agent` only if a shared engine is ever
   granted. (Whether para-agent's own `nu.js` one-shot stays is
   para-agent's call — its backend nu is a requirement there,
   independent of any console visitor.) Contract with
   the host is [notes/launch-surface.md](notes/launch-surface.md): the
   visitor engine is nushell-mcp's own pinned binary (**not**
   `PARA_NU_BIN` — the two nu dependencies are decoupled), and
   workspace-scoped spawn, which para-agent already guarantees, is
   what makes gh identity routing resolve correctly.

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

**Parked:** module prefixing — whether furnished capabilities carry a
`nu-` prefix to distinguish them from vendored utilities once
everything is `use`-pinned. Rationale accumulated in
[notes/module-prefixing.md](notes/module-prefixing.md); nothing
assumes it.

**Parked:** `par cap` terminal default (2026-08-23) — the coded
last-resort constant in `modules/par/mod.nu` (20000, doubling as the
silent catch for an *unparseable* `NU_MCP_OUTPUT_LIMIT`) smells: a
knob this load-bearing should be a shipped default in
`modules/par/policy.json` under the deployment declaration's override,
or a required config value that fails closed — not an internal
literal. A par amendment brief must settle precedence (a shipped
policy default should *lose* to the deployment declaration, which
inverts today's explicit-`max_inline_bytes`-wins order — or the two
cases need distinguishing) and whether a malformed declared value is
fail-as-data rather than a silent constant. The corpus already
documents the cap by meaning ([skills-corpus-v1](briefs/skills-corpus-v1.md));
nothing else assumes the constant.

Package rules (landing obligations, closed shapes, write conventions,
vocabulary) live in
[`mcp/nushell-mcp/AGENTS.md`](../../mcp/nushell-mcp/AGENTS.md), not
here. Term senses — whose word is whose — are in
[notes/vocabulary.md](notes/vocabulary.md).

## Briefs

| Brief | Status |
|---|---|
| [par-jobs-v1](.archive/briefs/par-jobs-v1.md) | landed 2026-08-21; amended 2026-08-22 (dataspection consumption) |
| [dataspection-v1](.archive/briefs/dataspection-v1.md) | landed 2026-08-22; archived |
| [layering-v1](.archive/briefs/layering-v1.md) | landed A 2026-08-22; archived |
| [hist-v1](.archive/briefs/hist-v1.md) | superseded → dataspection-v1 (primitives) + session-host-v1 (index) |
| [session-host-v1](briefs/session-host-v1.md) | filed, not started; parallel track |
| [xq-v1](briefs/xq-v1.md) | landed 2026-08-22; composition hardening landed 2026-08-23 |
| [rg-wrapper-v1](briefs/rg-wrapper-v1.md) | landed 2026-08-22; composition hardening landed 2026-08-23 |
| [composition-v1](briefs/composition-v1.md) | landed 2026-08-23 |
| [write-conventions-v1](notes/write-conventions-v1.md) | filed; governs every write (state vs scratch, locality, chronology, precedence) |
| [gh-v1](briefs/gh-v1.md) | filed; composition-v1 unblocked; then needs `gh` ≥ 2.40 in `deps/cli`; amended 2026-08-23 (overlay positioning) |
| [agent-porcelain-overlay](discussion/agent-porcelain-overlay.md) | discussion 2026-08-23; overlay track — nu-git-v1 then nu-gh-v1, briefs to file |
| [skills-corpus-v1](briefs/skills-corpus-v1.md) | landed 2026-08-23; corpus happy-path/appendix split, tree-aware `nu-skills` |
