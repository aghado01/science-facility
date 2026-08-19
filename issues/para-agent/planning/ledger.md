# Para-agent ledger — completed

Newest first. Evidence pointers are to commits, contracts, reports, and runner output.
Counts are recorded **with the commit they were observed at** (P16) — never as standing claims.

- **2026-08-19 — workspace root named; AGY capture rescued and P12 corrected**: `index.js` derived
  the workspace from `process.cwd()` inline at four points, never naming it — workspace-scoping was
  always the intent (supervisor and para-agent land in the same project), but the workspace itself
  was implicit, so transcripts had no override and no session could report its binding.
  `WORKSPACE_ROOT` now resolves once with `PARA_WORKSPACE_ROOT` overriding and `process.cwd()` as the
  documented default; `profiles.js` already carried the `PARA_PKG_ROOT` / `PARA_WORKSPACE_ROOT`
  distinction. Conventional-launch behavior unchanged. Bounded gate after the change:
  **21 suites / 218 discovered / 218 passed / 0 failed, skipped, or cancelled.**
  Separately, the 2026-08-14 AGY capture was found in gitignored `.codex/`, uncited: `agy 1.1.13`
  exited at Google OAuth timeout after 60s with **0 bytes of stdout**, so it never reached a stream.
  Moved to [specimens/agy-native-stream-capture-20260814](../specimens/agy-native-stream-capture-20260814/README.md);
  P12 amended to record an authentication-carrier gap rather than a stream finding. Both from
  [misplaced-artifacts-audit-20260819](../reports/misplaced-artifacts-audit-20260819.md).

- **2026-08-19 — fleet discovery census taken; grok compat discovery disabled** (config change by
  owner, plus a static census — no model call): `~/.grok/config.toml` now sets all six compat cells
  false for cursor, claude, and codex, after which Grok resolves repo-owned assets only. Census of
  all four installed clients + Cursor's orphaned config recorded in
  [client-discovery-inventory-20260819](../reports/client-discovery-inventory-20260819.md).
  Findings feeding P21: `filesystem`/`fetch`/`git`/`pwsh_exec` are declared across up to four
  scopes with drifting paths; this repository is trusted in three incompatible stores; Claude's
  `enabledMcpjsonServers` sits at *user* scope naming repo-owned server names globally; the repo's
  `AGENTS.md` reaches Grok and Codex but did **not** reach this Claude session; `.codex/` in-repo
  holds para-agent capture artifacts, not Codex config.

- **2026-08-19 — grok MCP load question re-probed; P10 narrowed to the runtime witness**
  (no code change, static probes only, no model call): the four "inherited" stdio definitions
  identified as Claude *user scope* (`~/.claude.json`), not unexplained config; documented
  no-load controls found and witnessed — `[compat.<vendor>] mcps = false` /
  `GROK_CLAUDE_MCPS_ENABLED` / `GROK_CURSOR_MCPS_ENABLED` flip all four to
  `compatibilityStatus: "disabled"`; repo-local `.mcp.json` confirmed default-deny behind folder
  trust (`~/.grok/trusted_folders.toml`); the Wave 0 `mcp list --json` contradiction retracted as
  a misreading of a registry-only command; `grok mcp doctor` disqualified as a load witness —
  it starts servers regardless of the compat gate. Folder trust then granted for this repository,
  after which para-agent starts under Grok: handshake `2025-11-25`, **17 tools discovered**,
  parity with its Claude surface. Record:
  [addendum](../reports/grok-1.0.4-wave0-evidence.md#addendum--2026-08-19-re-probe).
  Provenance argument split to [client-asset-provenance](../notes/client-asset-provenance.md),
  opened as P21.

- **2026-08-15 — planning canon minted** (this tier): decisions/roadmap/ledger seeded from the
  remediation and client-integration arcs. Both historical plans moved to [../reports/](../reports/)
  with superseded headers. Wave 0–4 numbering retired in favour of named tracks (P15); Grok
  reframed from delivery wave to extensibility acceptance test (P11).
  Bounded gate at `8fe3643`: **21 suites / 218 discovered / 218 passed / 0 failed, skipped, or
  cancelled** — verified by running `npm test`, not copied from prose. This corrected the W1
  entry's `216`, which was written before `cbce45a` landed.

- **2026-08-15 — version authority reworked** (`cbce45a`): pins made optional on both the
  integration profile and the host binding; adapter `verified_versions` demoted from launch/
  projection gate to evidence label; `assertApplicationVersion()` retained as an explicit evidence
  query with no production caller. Readiness now records the observed version and gates only
  against a non-empty allowed set
  ([readiness.js:389](../../../mcp/para-agent/src/client-integration/readiness.js:389)).
  Proven by [adapter-conformance.test.js:219](../../../mcp/tests/para-agent/adapter-conformance.test.js:219),
  which projects an observed `2.1.232` against the `2.1.226` fixture. Ruled as P6.

- **2026-08-15 — client-integration substrate landed** (`447d03c`, commit message misleadingly
  reads "wave 0"): registry, environment/policy, invocation compiler, readiness, workspace,
  carrier, scavenger, semantic-JSON; three client schemas; four bounded suites plus fixtures;
  manifest routing. 6,408 insertions across 29 files. Production mediation unchanged.

- **2026-08-15 — client integration contract frozen** (`d601288`):
  [CLIENT-INTEGRATION-CONTRACT.md](../../../mcp/para-agent/contract/CLIENT-INTEGRATION-CONTRACT.md)
  — authority model, policy lattice, environment/secret boundary, workspace and lane binding,
  descriptor shape, readiness dimensions, prompt carriers, lifecycle order, v1→v2 persistence
  transition, failure vocabulary, and an explicit Windows proof-status section. Documentation
  only; no runtime change. Bounded gate at that commit: 17 suites / 165 passed.

- **2026-08-15 — Grok 1.0.4 evidence captured, pilot ruled no-go** (W0-B → P10):
  version/help/inspect static probes completed with no model call. Exact unsandboxed scratch
  inspection found four inherited stdio MCP definitions while `mcp list --json` returned empty;
  the earlier sandboxed zero-server view was non-authoritative. Report:
  [grok-1.0.4-wave0-evidence.md](../reports/grok-1.0.4-wave0-evidence.md).

- **2026-08-14 — mediation remediation executed** (historical plan, now
  [../reports/sol-remediation-swarm-plan.md](../reports/sol-remediation-swarm-plan.md)): contract
  freeze → foundations → vertical slice → partial client conformance → guidance reconciliation.
  Landed `ProcessNativeClient`, `ConversationGate`, injected `ExchangeAssembler`,
  `MediatedTurnService`, typed `delegate`, read-only `scrutinize`, WAL acceptance/terminalization,
  per-conversation serialization, immutable raw-trace linkage, strict Nu with typed selectors, and
  schema-validated adapter profiles. Canonical boundary:
  [MEDIATED-EXCHANGE-CONTRACT.md](../../../mcp/para-agent/contract/MEDIATED-EXCHANGE-CONTRACT.md).
  Bounded gate at that checkpoint: 15 suites / 115 tests. Claude 2.1.226 pilot pass and a separate
  2/2 live Windows gate, both **predating** the final audit-hardening patch.

- **2026-08-14 — `ExchangeAssembler` rebuilt as a pure projection seam**: no I/O, no identity or
  index allocation, no clock, no adapter invocation, no provenance inference. Rejects
  caller-supplied indexes, out-of-store prompt records, unbound live model/application
  observations, fabricated non-completed replies, and success without complete raw-trace and
  adapter-emission evidence. Replaced a pre-remediation assembler that generated IDs and
  timestamps, read `nextIndex` before serialized commit, and substituted an application display
  name for missing live model identity.

- **2026-08-14 — remediation plan audited and approved**
  ([fable review](../reports/fable-sol-remediation-plan-review.md)): nine of nine audit claims
  reproduced at their cited locations. Two sharpenings folded into the contract freeze — the
  exchange schema was *unsatisfiable* rather than merely drifted (P3), and the two Nu bugs
  compounded into silent corruption, motivating the `NU-SCRUTINY-FALSE-SUCCESS` named regression
  and the `SUITE-ABORTED` runner contract (P4).

- **2026-08-14 — client-loading axes established**
  ([sol-client-loading](../notes/sol-client-loading.md)): the five composable axes and the ruling
  that invocation mode is explicit and owned by para-agent, never inferred from ambient shell
  behaviour or TTY detection. Ruled as P5; became the spine of the client-integration contract.

- **2026-08-13 — mediated-transcript ontology drafted**
  ([sol-transcript-drafting](../notes/sol-transcript-drafting.md)): para-agent owns a third
  transcript whose prompt and receiver trace carry asymmetric authorities. Ruled as P1; survives
  every subsequent revision intact.
