# Para-agent roadmap — ahead only

Completed items move to [ledger.md](ledger.md); rulings land in [decisions.md](decisions.md).

Tracks are **named, not numbered** (P15) — the two historical plans both used Wave 0–4 with
different meanings, and the collision is the single largest source of confusion in the corpus.
Ordering *within* a track is the current recommendation, not a contract. Tracks marked
independent may run in parallel.

The throughline: a client-agnostic launch/configuration/readiness/receipt substrate exists and is
bounded-green. What remains is cutting production mediation over to it, closing the honesty gaps,
and proving it by onboarding a fifth client through configuration alone.

## Track: grok-isolation — *independent, no code dependency*

The original impetus, and the only thing standing between the substrate and Grok. Settles P10.
Involves no para-agent source changes and does not wait on any other track.

1. **Establish whether grok 1.0.4 can be launched with no MCP servers loaded.** W0-B found four
   inherited stdio MCP definitions present under exact unsandboxed inspection while
   `mcp list --json` returned empty — so the empty listing is not evidence of non-loading.
   Determine whether a clean-config invocation, an explicit empty allowlist, or a documented
   no-start flag actually prevents load *and* start.
2. **Decide the fallback if it cannot be proven.** Either Grok never receives managed mediation
   (console surface only), or it is onboarded with tool isolation explicitly recorded as
   `unknown` and gated behind a documented risk acceptance. Do not leave this implicit.
3. **Record the result in [decisions.md](decisions.md) P10** as ruled either way, with the exact
   probe and its proof limit. `grok inspect --json` remains configuration-only evidence.

No authenticated turn, model call, or session artifact until this track closes.

## Track: substrate-migration — *independent of grok-isolation*

Cut production mediation onto the client-integration substrate. Everything here lands together —
there is never more than one active command authority.

1. **Remove command authority from adapters.** Adapters own encoding, parsing, correlation, and
   native projection only.
2. **Inject registry + compiler into `MediatedTurnService`**; `ProcessNativeClient` consumes the
   final plan with no ambient `process.env` merge.
3. **Strict `spawn` tagged union** — existing shell pane, existing raw command pane, managed
   `application + sessionProfile` pane. Mixed shapes reject rather than being silently ignored.
4. **Header-pinned v1/v2 persistence** (P9): v2 header and rows for new ledgers, v1 read/recovery/
   admin preserved, new v1 acceptance rejects with `TRANSCRIPT_UPGRADE_REQUIRED`.
5. **Three profiles land atomically** — Claude, Codex, AGY (AGY fail-closed per P12) — together
   with the adapter command removal and the runtime cutover.
6. **Golden plans** prove Claude/Codex default invocation compatibility. **Blocked on P18** —
   decide the readiness-version normalization before writing goldens, or they will be
   machine-dependent from birth.

Exit: the bounded manifest passes with no failure, skip, cancellation, or abort, and the count is
recorded with its commit (P16). Live Windows evidence is recorded separately; pending is not
live-verified.

## Track: honesty-gaps — *after migration, except P17 which precedes it*

Each of these is a place where the documentation currently claims more than the code delivers.
Three were carried unresolved across both historical plans.

1. **`NATIVE_APPLICATION_VERSION_MISMATCH` (P17) — implement or demote.** Decide *before* the
   migration lands, because P6 made this the only remaining live version check and it is
   specified as post-acceptance. Either give it a throw site plus a test, or demote it in the
   contract to reserved-and-unimplemented. It must not stay specified-but-absent.
2. **Golden-plan determinism (P18).** Synthetic readiness injection or version-fact
   normalization; then write the goldens.
3. **AGY fresh native stream capture**, then profile enablement (P12). Carried from the
   remediation sequence's client-conformance track, still partial.
4. **Live Windows gate recertification** against current source. The last 2/2 pass predates the
   final audit-hardening patch and every commit since.
5. **Egress post-commit question (P19)** — resolve and record.
6. **Windows proof gaps (P20)** — either implement the DACL/lock-retry/scavenging/reparse
   containment witnesses, or keep the release language explicitly qualified. No silent skips.

## Track: grok-onboarding — *requires grok-isolation + substrate-migration*

This is the acceptance test, not a delivery (P11). The success criterion is not "Grok works" —
it is **"Grok was added through profiles and codecs only, with zero changes to generic services."**
Any generic-service change required here is a substrate defect, and the finding is more valuable
than the client.

1. Integration profile, host binding, session profile, adapter + native fixture.
2. Constrained first mode: headless streaming JSON, verbatim, evidenced non-argv carrier, no
   memory/subagents/web/unapproved tools, read-only permissions.
3. Conformance against the common adapter/integration suites; exact reply reconstruction
   including streamed chunks.
4. One live constrained turn — prompt, terminal, trace, receipt, digest — only after
   grok-isolation closed affirmatively.
5. Mutation census: no repo change; expected external session artifacts reported.

If stream, tool isolation, or carrier conformance fails, land Grok as explicitly unverified. The
substrate stays green either way.

## Deferred

Unchanged from both historical plans, restated so they cannot fall out. These become consumers
only after the launch, environment, readiness, prompt, and receipt contracts are trustworthy.

- Native resume/continue, async handles, wake signals.
- ACP / app-server control transports.
- Session Continuity and reconstructed GGUF context.
- Shared-MCP deployment and projection.
- Addressable length-prefixed context framing.
- Personas and general swarm-guidance redesign.
- Privileged global-client configuration edits.
- Secret-capable managed mux injection, unless a non-argv backend is evidenced.
- Hashish absorption, a general Artifact engine, broad tool-surface redesign.
