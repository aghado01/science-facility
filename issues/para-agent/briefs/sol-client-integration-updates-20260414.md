# Para-Agent Client Integration and Grok 1.0.4 Execution Brief

> **SUPERSEDED (2026-08-15) — historical plan, not current status.**
> Current canon is [../planning/](../planning/): [decisions.md](../planning/decisions.md),
> [roadmap.md](../planning/roadmap.md), [ledger.md](../planning/ledger.md).
> Design authority is [CLIENT-INTEGRATION-CONTRACT.md](../../../mcp/para-agent/contract/CLIENT-INTEGRATION-CONTRACT.md),
> which this document paraphrases lossily — where the two disagree, the contract wins.
>
> Known-stale in this file: the reviewed baseline (`d0b7984`, "eight commits ahead") was never
> refreshed; W0 and W1 read `ready-to-commit` though both landed (`d601288`, `447d03c`); the
> W2-E gate cites `165` after W1 moved the baseline to `216`, and the true figure at `8fe3643`
> is `218`; and the version-authority section was rewritten without updating the W2-C fixture
> gate that depended on the old rule. The Wave 0–4 numbering collides with the identically
> numbered sequence in [sol-remediation-swarm-plan.md](sol-remediation-swarm-plan.md).
> Retained as planning and audit evidence.

## Objective and execution state

- Build a client-agnostic launch, configuration, readiness, and receipt substrate.
- Atomically migrate Claude, Codex, and fail-closed AGY.
- Add Grok only after the substrate and existing clients are bounded-green.
- Preserve mediated-transcript, native-evidence, and console boundaries.
- Execute in five waves with at most three workers plus root.

Checkpoints:

- [x] Architecture reviewed and amendments incorporated.
- [x] Current bounded tree verified: **21 suites / 216 passed / 0 failed, skipped, or cancelled**.
- [x] User authorized Wave 0; three read-only evidence lanes completed.
- [x] W0 contract/evidence freeze; the gated Grok pilot is explicitly no-go.
- [x] W1 fake-client substrate.
- [ ] W2 atomic existing-client migration.
- [ ] W3 Grok verification or explicit unverified fallback.
- [ ] W4 release audit.

## Reviewed baseline

- Review HEAD: `d0b7984` on `main`, eight commits ahead of `origin/main`.
- The current para-agent and test trees are identical to those used for the 165-test run.
- No live Windows gate or Grok model call ran during review.
- Unrelated untracked path: `issues/reposnapshot/discussion/Claude-987e56e0-c6cc-44f9-9264-338c54bbb9a8.md`.
- Root refreshes HEAD, branch divergence, versions, and worktree state at every wave start.
- Root stages named paths only and commits to `main`.

Observed clients:

- Grok `1.0.4 (d846eb93d9)`.
- Codex `0.147.0`, matching its verified fixture.
- Claude `2.1.232`; its verified profile/fixture is `2.1.226`.
- AGY `1.1.13`, intentionally unverified.

Claude live tests use the current executable. Bounded fixtures remain `2.1.226`; live-verified claims name the observed version and do not require a configuration pin.

## Frozen design

- **Application adapter**
  - Owns prompt encoding, native events, correlation, terminal evidence, native identity, and reply assembly.
  - Owns no executable, cwd, environment, readiness, or process authority.
- **Client integration profile**
  - Owns executable identity, supported surfaces/modes, fixed arguments, stdio, prompt carrier, readiness, and policy projections.
- **Host binding**
  - Owns executable overrides, workspace aliases/roots, and named environment or credential sources.
  - Contains no committed secrets and performs no global-client mutation.
- **Session profile**
  - Names client-agnostic workspace, memory, subagent, web, tool, and permission policy.
  - Is launch policy, not native resume or Session Continuity.
- **Configuration provider**
  - Loads one validated immutable snapshot through `ClientConfigProvider`.
  - JSON Schema/JSON is the first provider, not a permanent domain dependency.
- **Invocation compiler**
  - Before acceptance, produces an immutable exchange-independent recipe and separately constructed safe descriptor.
  - After acceptance, fills only declared exchange-bound carrier/runtime slots and produces the final immutable plan.
- **Execution backends**
  - Process and mux backends execute plans only; they interpret no client semantics.
- **Mediation**
  - `MediatedTurnService` owns accepted-turn orchestration.
  - Console and managed-pane activity never imply mediated exchanges.

Policy:

- Functional defaults resolve package → host → session profile → allowed operation controls.
- Package and host policy form security ceilings; later controls may only narrow them.
- Unsupported, ambiguous, or widening mappings fail closed.
- CLI flags are compiled output, not a fifth authority.
- Equivalent redacted semantic policy has a versioned stable digest.

Identity and lane binding:

- Public `application` selects configuration; it is not provenance.
- Application/model/native identity comes only from correlated receiver-native evidence.
- Readiness version is launch evidence, never receiver-native `application.version`.
- Each `application + handle` binds to one integration revision, session-policy digest, and stable workspace identity.
- Incompatible profile/cwd reuse fails closed; callers use a new handle for a new context.
- Receipts use configured workspace identifiers, never host paths.

Environment, secrets, and paths:

- Package/session configuration uses named sources, not literal secret values.
- Para-agent never originates secret values in argv, public/durable receipts, generated errors/logs, policy digests, invocation descriptors, fixtures, snapshots, or test output.
- Exact prompts and receiver-native content, including traces, normalized records, and final replies, remain privileged/untrusted and cannot promise redaction if a caller or client emits a secret.
- Managed mux panes reject secret sources and remain unavailable until isolated control-environment and pane inheritance are evidenced.
- Raw `spawn(command, env)` and `exec(command, env)` remain legacy escape hatches outside the managed guarantee.
- Windows environment names are case-insensitive; collisions and invalid names reject.
- The compiler emits the complete child environment; backends do not re-merge ambient `process.env`.
- Managed cwd is a logical relative selector resolved to a configured non-path `working_directory_id`; absolute, rooted, dot-segment, missing, and reparse-traversing forms reject.
- Request cwd affects only the child invocation. The server-owned workspace and handle select the transcript store, so cwd cannot reroute a ledger or bypass lane binding.

Readiness and acceptance:

1. Validate request, derive the exact conversation key, and resolve the fixed handle-owned transcript route.
2. Open/scan the store, complete recovery, and restore durable quarantine into the process gate.
3. Acquire the conversation gate.
4. Pin one immutable configuration snapshot; resolve binding and policy.
5. Compile the private recipe and descriptor basis; run bounded readiness and exchange-independent carrier validation, then finalize the safe descriptor from allowlisted facts.
6. On preflight failure, clean resources and release the gate without acceptance.
7. Durably accept the descriptor; the store allocates the exchange ID and rechecks lane binding.
8. Bind the gate, initialize trace capture, encode/materialize the exchange-bound carrier, and finalize the private plan.
9. Execute, capture separate semantic/diagnostic streams, project native evidence, and commit one terminal result and marker.
10. Clean artifacts and construct MCP egress only after terminal durability.

- Readiness reports executable, version, configuration, authentication, capabilities, environment sources/exactness, workspace, prompt carrier, and backend separately as `passed | failed | unknown | not_applicable`.
- `unknown` stays unknown; `grok inspect --json` does not by itself prove authentication.
- Only evidenced preflight failures are guaranteed to occur before acceptance.
- Post-accept encoding/materialization failure invokes no native client and durably terminalizes once with confirmed native stop.

Prompt carrier:

- Prompt content never enters argv.
- The carrier preserves exact UTF-8 for the accepted well-formed Unicode string.
- Prefer evidenced stdin. Prompt files require a private physical runtime root, verified POSIX modes or Windows DACL, no reparse traversal, exclusive creation, sync/readback, opaque names, and no public path disclosure.
- Cleanup follows confirmed native close, uses bounded Windows-lock retry, reports unresolved deletion as `PROMPT_CARRIER_CLEANUP_PENDING`, and includes conservative crash-orphan startup scavenging.

Persistence:

- W2 adds a row-0 v2 header and v2 transcript, acceptance, terminal-marker, and required recovery/reconciliation row schemas.
- One immutable header pins one dialect. New ledgers write v2 only; v1 ledgers remain readable/queryable and eligible for same-dialect recovery/admin but reject new normal acceptance with `TRANSCRIPT_UPGRADE_REQUIRED`.
- New work against a v1 route uses a new mediation-ledger session/handle; no v2 row is appended under a v1 header and no v1 header is rewritten.
- V2 acceptance and terminal rows carry and equality-check the same store-copied safe invocation descriptor.
- The descriptor contains integration/adapter/session revisions, surface/mode, workspace and working-directory IDs, separate session/effective policy digests, carrier/stdio kinds, and allowlisted non-secret readiness facts.
- It contains no executable path, cwd, environment names/values, secret references, or host topology.
- Existing v1 stores receive explicit read, recovery, reconciliation, and new-accept rejection tests.
- `MEDIATED-EXCHANGE-CONTRACT.md` is updated with this lifecycle and schema contract.

## Public surface

- `delegate` gains optional logical `cwd` and `sessionProfile` selectors; `application` remains the selector.
- `delegate` accepts no arbitrary environment, executable, flag, or secret fields.
- `spawn` becomes a strict union:
  - Existing shell pane.
  - Existing raw `command` program pane.
  - Managed `application + sessionProfile` pane.
- Mixed-shape fields reject rather than being ignored.
- Managed panes remain console surfaces and create no mediated exchange.

## Swarm controls

- Root alone edits this brief/status ledger, shared runtime wiring, the shared test manifest, and wave commits.
- Each dispatch reserves exact shared paths and grants workers exclusive files/directories.
- Workers do not commit or broadly format; they report changed paths, exact tests, assumptions, and untouched reservations.
- Root rechecks HEAD/worktree before integration.
- Concurrent edits to owned paths stop the wave; unrelated changes remain untouched.
- `mcp/tests/para-agent/test-manifest.json` plus `run.ps1` is bounded authority.

## Wave 0 — Contract and evidence freeze

Parallel read-only lanes:

- **`grok-protocol`**
  - Capture Grok 1.0.4 help/inspect/stream facts, terminal event, session identity, reply assembly, carrier, and stderr topology.
- **`integration-contract`**
  - Freeze adapter/integration/config boundaries, version authority, lane binding, typed failures, and v1/v2 persistence.
- **`environment-security`**
  - Freeze policy ceilings, environment/cwd behavior, secrets, stdio, prompt-file security, cleanup, redaction, and managed-mux limits.

Root outputs:

- `mcp/para-agent/contract/CLIENT-INTEGRATION-CONTRACT.md`.
- `issues/para-agent/reports/grok-1.0.4-wave0-evidence.md`, including the fixture matrix and current-client disposition.
- Configuration/readiness/failure vocabulary.
- Exact non-argv prompt-carrier decision.
- Explicit Windows sandbox status.

Checkpoints:

- [x] **W0-A Evidence:** version-labelled static facts captured; semantic stdout and diagnostics remain distinct; every readiness probe states its proof limit.
- [x] **W0-B Safety decision:** no-go. Exact unsandboxed scratch inspection discovered four inherited stdio MCP definitions while `mcp list --json` was empty; no no-load/no-start control is proven.
- [x] **W0-C Guard:** no authenticated turn, model cost, or session artifact. Reopen only after the evidence report's clean-config and tool-isolation conditions pass.
- [x] **W0-D Exit:** carrier, policy, secrets, lane binding, readiness, v2 ledger transition, Claude drift, and missing Grok evidence dispositions are frozen; reply reconstruction remains explicitly unverified.
- Append W0 status and pass scoped diff/verification checks.

Commit: `para-agent: freeze client integration contract`

## Wave 1 — Client-agnostic substrate

Parallel ownership:

- **`client-registry`:** schemas, registry, cross-profile validation, fake profiles, immutable snapshots.
- **`environment-config`:** providers, policy intersection, final environment, workspace identity, redaction, digest.
- **`invocation-core`:** pure plan compiler, readiness, stdio, carriers, cleanup/scavenging.

Likely roots: `src/client-integration/`, `src/clients/`, and three client integration/host/session schemas.

Required coverage:

- Invalid present configuration fails startup atomically; missing optional binding yields typed unavailability.
- Security cannot widen; environment casing/unset/inheritance is deterministic; managed mux secrets fail closed.
- No generated output leaks secrets or host paths.
- Cwd traversal and symlink/junction/reparse escapes reject with real Windows witnesses and no silent skip.
- Hostile valid Unicode survives carriers exactly and never enters argv.
- Cleanup covers success, failure, timeout, cancellation, Windows locks, and crash orphans.
- Readiness handles absence, timeout, malformed output, proof gaps, version drift, environment exactness, carrier, and backend capability.
- Plans, snapshots, and redacted digests are deterministic and immutable.

Checkpoints:

- **W1-A Contracts:** schemas/providers pass against fakes.
- **W1-B Security:** environment, cwd, secret, carrier, and cleanup suites pass.
- **W1-C Exit:** complete fake-client layer is bounded-green; production mediation is unchanged.
- [x] Append W1 status before commit.

Commit: `para-agent: add client integration substrate`

## Wave 2 — Atomic existing-client migration

Root owns:

- Removal of command authority from adapters.
- Registry/compiler injection into `MediatedTurnService`.
- Final-plan consumption by `ProcessNativeClient` with no ambient environment merge.
- Strict shell/raw/managed `spawn` union.
- Header-pinned v1/v2 persistence, v1 new-accept rejection, contract updates, shared wiring, and manifest.

Profile workers:

- **`claude-migration`:** current evidence, adapter, integration, environment declarations, conformance.
- **`codex-migration`:** Codex equivalents.
- **`agy-migration`:** AGY equivalents while mediation remains fail-closed.

Version authority:

- Integration profiles own executable resolution and optional version pins.
- Host bindings omit `expected_version` unless a caller explicitly pins.
- Adapter `verified_versions` is evidence, not a launch or projection gate.
- Readiness records the current observed version. Drift fails only against an explicit pin.

Atomicity:

- Adapter command removal, all three profiles, and runtime cutover land together.
- Golden plans prove Claude/Codex default invocation compatibility.
- There is never more than one active command authority.

Checkpoints:

- **W2-A Persistence:** v1 read/recovery/admin opens but rejects new acceptance; new v2 ledgers write one dialect and descriptors match exactly.
- **W2-B Runtime:** readiness and carrier feasibility precede acceptance; exchange-bound encoding/materialization follows acceptance and every accepted turn terminalizes.
- **W2-C Compatibility:** Claude/Codex fixtures and golden plans remain exact; AGY fails closed.
- **W2-D Surface:** shell/raw/managed spawn modes reject mixed fields.
- **W2-E Exit:** original 165 plus all new manifest tests pass with no failure, skip, cancellation, abort, or count mismatch.
- Record live Windows evidence separately; pending is not live-verified.
- Append W2 status before the atomic commit.

Commit: `para-agent: migrate clients onto integration substrate`

## Wave 3 — Grok 1.0.4

Parallel ownership:

- **`grok-native`:** adapter, native fixture, event/terminal mappings, reply-chunk codec if needed.
- **`grok-integration`:** executable/mode profile, environment, cwd, readiness, policy projections.
- **`grok-e2e`:** independent conformance, MCP round-trip, live harness, census, digest checks.

Initial constrained mode:

- Headless `streaming-json`, `--verbatim`, and evidenced `--prompt-file` or equivalent.
- No memory, subagents, web, or unapproved MCP tools.
- Read-only/tool-disabled permissions and configured project cwd only after a documented clean config/no-MCP-load scope passes exact-context inspection.
- `grok inspect --json` is configuration-only evidence.
- Exact version gate on `1.0.4`.
- Model/capability/native IDs stay absent unless the native stream exposes them.
- Windows sandbox stays `unknown` or `unsupported` without enforcement evidence.

Checkpoints:

- **W3-A Conformance:** `grok/1.0.4` passes common adapter/integration suites.
- **W3-B Reconstruction:** final reply is exact, including streamed chunks.
- **W3-C Preflight:** drift fails before acceptance and proof levels remain honest.
- **W3-D Live:** one constrained turn passes prompt, terminal, trace, receipt, and digest checks.
- **W3-E Mutation:** census finds no repo change; expected external session artifact is reported.
- **W3-F Exit:** bounded/live evidence is labelled separately and W3 status is appended.

If stream, tool isolation, or carrier conformance fails, land Grok only as unverified; W1–W2 remain green.

Commit: `para-agent: add verified grok 1.0.4 client`

## Wave 4 — Hardening and release audit

Parallel ownership:

- **`security-audit`:** secrets/paths, widening, collisions, cwd escapes, artifacts, cancellation, cleanup, raw-trace boundary, sandbox claims.
- **`extensibility-audit`:** add a fake fifth client through profiles/codecs only.
- **`release-reconciliation`:** README, contracts, Grok notes, skills, status, and verification labels.

Checkpoints:

- **W4-A Architecture:** generic services contain no client-specific literals or branches; compiled values remain opaque plan data.
- **W4-B Security:** managed guarantees, privileged raw traces, prompt/process cleanup, and no global configuration mutation are accurate.
- **W4-C Extensibility:** fifth client needs no backend semantic change.
- **W4-D Verification:** manifest coverage is complete; bounded counts are exact; existing Windows and Grok live gates pass separately or remain explicitly pending.
- **W4-E Release:** reports separate implemented, bounded-verified, live-verified, unverified, deferred, and worktree state.
- Append W4 status, stage named paths, and commit to `main`.

Commit: `para-agent: harden client integration release`

## Wave status ledger

Root appends after verification and before the wave commit. The containing commit anchors the entry.

### Entry template

- **Wave / UTC:**
- **State:** ready-to-commit | committed | failed-gate
- **Base HEAD / prior wave HEAD:**
- **Owned paths:**
- **Implemented:**
- **Bounded verification:**
- **Live verification:**
- **Unverified/deferred:**
- **Failures/deviations:**
- **Worktree/unrelated changes:**
- **Next checkpoint:**

### W0 contract and evidence freeze

- **Wave / UTC:** W0 / 2026-08-15T01:56:37Z
- **State:** ready-to-commit
- **Base HEAD / prior wave HEAD:** `d0b7984ba29b1ee3a91764aac51f2858baaf355d` / none
- **Owned paths:**
  - `issues/para-agent/briefs/sol-client-integration-updates-20260414.md`
  - `issues/para-agent/reports/grok-1.0.4-wave0-evidence.md`
  - `mcp/para-agent/contract/CLIENT-INTEGRATION-CONTRACT.md`
- **Implemented:** Wave 0 contract/evidence documentation only; runtime, schemas, profiles, fixtures, and manifest were not changed.
- **Bounded verification:** manifest runner passed **17 suites / 165 discovered, completed, and passed / 0 failed, skipped, or cancelled**; `git diff --check` passed; Grok 1.0.4 static version/help/inspect probes completed without a model call.
- **Live verification:** none. The Grok safety gate was no-go, so no authenticated turn or live Windows client gate ran.
- **Unverified/deferred:** Grok MCP non-startup, built-in empty-allowlist semantics, authentication, runtime NDJSON, terminal/reply reconstruction, prompt-file cleanup, and Windows sandbox; Claude 2.1.232 protocol compatibility; exact Windows child-environment enforcement, prompt DACL/locking/scavenging, and real reparse containment.
- **Failures/deviations:** exact unsandboxed scratch inspection discovered four inherited stdio MCP definitions while `mcp list --json` returned empty; the earlier sandboxed zero-server view was non-authoritative. Current transcript/trace ACL inheritance does not support a strong local confidentiality/immutability claim.
- **Worktree/unrelated changes:** before the Wave 0 commit, only the three owned paths are in scope; unrelated untracked `issues/reposnapshot/discussion/Claude-987e56e0-c6cc-44f9-9264-338c54bbb9a8.md` remains untouched. The exclusive empty Grok scratch directory was removed after inspection.
- **Next checkpoint:** obtain explicit Wave 1 authorization, then build the fake-client substrate without changing production mediation.

### W1 fake-client substrate

- **Wave / UTC:** W1 / 2026-08-15T04:28:23Z
- **State:** ready-to-commit
- **Base HEAD / prior wave HEAD:** `e197b61` / `d0b7984`
- **Owned paths:**
  - `mcp/para-agent/src/client-integration/`
  - `mcp/para-agent/src/schemas/client-host-binding.schema.json`
  - `mcp/para-agent/src/schemas/client-integration-profile.schema.json`
  - `mcp/para-agent/src/schemas/client-session-profile.schema.json`
  - `mcp/tests/para-agent/client-registry.test.js`
  - `mcp/tests/para-agent/client-environment.test.js`
  - `mcp/tests/para-agent/client-invocation.test.js`
  - `mcp/tests/para-agent/client-integration.test.js`
  - `mcp/tests/para-agent/fixtures/client-integration/`
  - `mcp/tests/para-agent/test-manifest.json`
- **Implemented:** W1 registry/environment/invocation substrate and cross-layer fixtures/tests completed; manifest routing and integration assertions added; test-coverage now includes fake-client readiness/invocation/cleanup hardening.
- **Bounded verification:** `PARA_MANIFEST_SUMMARY {"schema_version":1,"suites":21,"discovered":216,"completed":216,"passed":216,"skipped":0,"cancelled":0}`
- **Live verification:** none.
- **Unverified/deferred:** Grok 1.0.4 integration, existing-client migration, and live Windows enforcement claims.
- **Failures/deviations:** none within W1 bounded scope.
- **Worktree/unrelated changes:** unrelated untracked issue and snapshot paths remain.
- **Next checkpoint:** authorize W2 and migrate Claude/Codex/AGY onto the substrate.

## Explicitly deferred

- Native resume/continue, async handles, and wake signals.
- ACP/app-server control transports.
- Session Continuity and reconstructed GGUF context.
- Shared-MCP deployment/projection.
- Addressable length-prefixed context framing.
- Personas and general swarm guidance redesign.
- Privileged global-client configuration edits.
- Secret-capable managed mux injection unless W0 evidences a non-argv backend.

These become future consumers only after the launch, environment, readiness, prompt, and receipt contracts are trustworthy.
