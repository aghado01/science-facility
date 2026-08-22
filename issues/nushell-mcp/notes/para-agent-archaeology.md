# para-agent archaeology — what nushell-mcp must not reinvent

**Written:** 2026-08-21 · **Status:** findings + recommendations; the
amendments it calls for are applied to
[session-host-v1](../briefs/session-host-v1.md) in the same commit.
**Read:** `mcp/para-agent/{README,AGENTS}.md`, `contract/CONSOLE-CONTRACT.md`,
`src/{nu,journal,capture,framing,identity,mux,index}.js`,
`issues/para-agent/notes/{visitor-mcp-registration,session-scoped-inheritance-control}.md`,
commit `2561e76` (the extraction).

## 1. What the "original nushell-mcp" inside para-agent actually was

Two things, neither of which is what we are building now:

- **`skills/nu/SKILL.md`** (21 lines, removed in `2561e76`) plus
  **`src/nu.js`** (still present): one-shot structured execution —
  spawn a `nu` per call, wrap the script in a `do {} catch {}` program
  that prints a JSON envelope (`protocol: para-agent.nu.v1`, `ok`,
  `error`, `exit_code`). Stateless by construction. This is the
  `pwsh_exec` model. `nu.js` is dead weight now and should be retired
  when the visitor registry lands.
- **Nu as a pane dialect.** `framing.js` has `DEFAULT_DIALECT = "nu"`;
  `capture.js` runs framed/captured commands in a multiplexer pane
  whose shell is `nu` (`PARA_NU_BIN`). Persistent — the pane outlives
  calls — but **textual**: bodies are bytes from a PTY, not values.

So para-agent never had engine persistence. It had *pane* persistence
(text, via psmux) and *structured* execution (stateless, via `nu.js`),
as two separate things. `nu --mcp` is the first time the layer gets
both at once: a persistent engine whose outputs are values. That is
the stand-alone MCP's reason to exist, and the reason it is a visitor
capability rather than a pane dialect.

## 2. The persistent-console model that already exists (Console plane)

`README.md` states the thesis in one paragraph: an MCP tool call is a
fresh process; a multiplexer server is a daemon that outlives every
command; panes keep variables, cwd, env, running programs across
turns — "a genuinely persistent interactive console." Tools:
`spawn list kill send read wait run exec log body find status`.

The implicit assumptions nushell-mcp inherits from this, and must
honor to feel like the same product:

| Assumption (para-agent) | nushell-mcp equivalent |
|---|---|
| A session is a named, long-lived thing the agent returns to | an engine child per `(session, agent)`, keepalive across client disconnect |
| `run` returns a **receipt**, not output; `body` fetches a payload on demand | `evaluate` result + journal `out` record; `body` for deferred bodies; in-engine `jobs read` |
| Bodies are byte-exact files beside the journal, never truncated by the transport | NUON bodies as files (`turns/<seq>.out`) when over the inline limit |
| Every read returns a receipt, unconditionally; `complete`/`withheld` name retrieval | adopt verbatim (see §3) |
| Cursor = one integer (`seq`), reader-owned | adopt; `history_index` is the engine's turn number |
| Cancellation is cooperative and recorded (`.cancel`, `outcome: cancelled`) | `jobs cancel` in-engine; host records `exit.outcome` |
| Producers that lose data **must** say so (`note`) | engine restart / lost `$history` → `note` + `outcome: died` |

## 3. Console Journal Contract v1 — adopt it, do not parallel it

`contract/CONSOLE-CONTRACT.md` is a *format-based* contract: "any
producer that emits conforming records is a valid source, and the
reader must not care which one wrote them." That sentence is the
plug-in seam. The session host becomes **a new producer** of
conforming journals (one stream per engine session), and para-agent's
existing reader (`log`/`body`/`find`) works over engine streams with
no code dependency in either direction — consistent with para-agent's
own rule that "a plugin is not a dependency" (`e577360`).

What the host writes, per evaluate:

- `turn` — `cmd` = the `input` verbatim, `cwd` from the engine result,
  `shell: "nu"`, `origin: "evaluate"`, `cmd_hash`.
- `out` — `bytes`/`lines`/`out_hash` over the NUON output; `text`
  inlined when `bytes <= inlineLimit`, else `ref` to `turns/<seq>.out`
  + `preview`. `truncatedInline: false`, always.
- `exit` — `ok` from the engine result, `code: null` (no process),
  `duration_ms` host-measured, `outcome: completed | died`.
- `note` — engine spawn/respawn/keepalive-expiry; `data` carries
  `meta` lifted from stamped receipts (`kind`, `tag`, `ref`) and agent
  annotations (`tags`, `note`), keyed by `turn`.

Contract amendments this needs (small, additive): `shell` gains `nu`;
`origin` gains `evaluate`; `note.data` is already free-form. File them
against para-agent's contract rather than forking a v2.

The contract's **design priorities** — no silent omission, token
economy, selectivity, facility — are nushell-mcp's doctrine stated
more precisely than the roadmap states it. Import them. In particular
"every `withheld` entry names a concrete call that retrieves it" is
the rule `truncated: true` + `tag` was groping toward in the par-jobs
envelope; say it that way.

## 4. Identity and governance are already split the right way

`notes/visitor-mcp-registration.md` (2026-08-19) names nushell-mcp as
the canonical **visitor MCP**: "long-lived stdio JSON-RPC server,
shared across turns and participants … a sibling MCP, instrumental but
not owned." Two registries, deliberately: the *client* registry
answers "what is Grok and how do we speak to it"; the *visitor*
registry answers "may this participant reach this capability."

Consequence for the host: **governance (may X reach nushell-mcp) is
para-agent's; routing (which engine does X get) is the host's.** The
caller-routed identity doctrine already says this — the host accepts
`(session_id, agent_id)` from whoever launches it and never decides
who is allowed. `notes/session-scoped-inheritance-control.md` adds the
posture *label, don't gate*: a participant whose isolation is not yet
characterized still runs, labeled. The host should do the same: an
unknown caller gets the configured default identity and a `note`
saying so, not a refusal.

`identity.js` contributes one rule worth copying: identities are
validated as well-formed Unicode scalar sequences before being hashed
or routed to storage, so two logical identities can never collide
through replacement characters in a filename.

## 5. Name collision: "quarantine"

In para-agent, *quarantine* is the mediation plane's
**ambiguous-commit quarantine** — durable evidence that a transcript
commit could not be proven, inspected read-only via
`quarantine_status`, mutated only by an offline CLI under a writer
lease. It is a safety/evidence term with a CLI behind it.

nushell-mcp has been using "payload quarantine" for deferring bodies
out of context. Once the two share a host, that overloading will
mislead. Recommendation: nushell-mcp docs adopt the journal's word —
**deferred bodies** (and `stash` for the in-engine act) — and retire
"quarantine" from the roadmap doctrine and the `xq` brief title. Nu
verb names are unaffected (`jobs stash`, `jobs emit` never said it).

## 6. Things that do *not* transfer

- `framing.js` (marker bracketing, `waitStable`, `deltaOf`) and
  `capture.js`'s `.done` sentinels solve PTY problems the engine does
  not have — JSON-RPC has completion and exit built in. Do not import.
- The mediation plane (`delegate`, transcripts, adapters, raw traces)
  is a different evidence system; the host never touches it.
- `brewery/build/deps` layout: nushell-mcp already mirrors it. One
  divergence to decide deliberately: para-agent keys executables as
  `deps/bin/{tool}`; nushell-mcp uses `deps/cli` + `deps/nushell`.
  Harmless while stand-alone; align to `deps/bin/` only if para-agent
  ever rehydrates nushell-mcp's deps through its brewery.

## 7. Recommendations (applied / to apply)

1. **Applied:** session-host-v1 ledger → Console Journal Contract v1
   producer; tools renamed `log`/`body`/`find` (+ `annotate`,
   `console`); bodies as files beside the journal; unconditional
   receipts with `complete`/`withheld`/`deferredBodies`.
2. **To file against para-agent:** contract amendment (`shell: nu`,
   `origin: evaluate`); retire `src/nu.js` and `PARA_NU_BIN` one-shot
   when the visitor registry lands; optionally contribute
   `console-journal.schema.json` (the contract is prose-only today —
   a schema both sides validate against is a shared artifact with no
   code coupling).
3. **Roadmap doctrine:** replace "payload quarantine" with "deferred
   bodies"; import the four design priorities by name.
4. **Do not** make nushell-mcp import para-agent code, ever. The
   contract is the coupling; para-agent's rule, and ours.
