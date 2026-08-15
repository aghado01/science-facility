# Para-Agent Client Integration Contract v1.0

- **Status:** Wave 0 design freeze; implementation begins in Wave 1
- **Schema dialect:** JSON Schema 2020-12
- **Scope:** managed client configuration, invocation, readiness, and evidence

This contract extends, but does not replace, the mediated-exchange and console
contracts. It freezes authority and failure boundaries before production code is
migrated. Current behavior is not evidence that every rule below is implemented.

## Scope and non-goals

- One client-agnostic substrate serves Claude, Codex, AGY, Grok, and fake clients.
- Managed mediation and managed panes consume validated configuration snapshots.
- Legacy shell/raw `spawn` and `exec` remain explicit escape hatches outside the
  managed security guarantee.
- Native resume, Session Continuity, ACP/app-server control transports, global
  client configuration mutation, and shared-MCP deployment are not part of v1.0.

## Authority model

| Component | Owns | Must not own |
|---|---|---|
| `ApplicationAdapter` | Exact native payload encoding; semantic parsing; correlation; receiver-native identity, terminal, and reply projection | Executable, argv, cwd, environment, readiness, carrier mechanism, or process lifecycle |
| `ClientIntegrationProfile` | Logical executable and version constraints; fixed argv templates; surfaces/modes; carrier and stdio topology; readiness recipes; policy projections | Concrete host paths, credentials, native provenance, or process execution |
| `HostBinding` | Concrete executable resolution; named workspace, working-directory, environment, and credential sources | Policy widening, literal committed secrets, or native provenance |
| `SessionProfile` | Client-agnostic workspace, memory, subagent, web, tool, and permission selections | Native session continuity or executable resolution |
| `ClientConfigProvider` | One validated immutable snapshot and stable revisions | Runtime execution or backend semantics |
| `InvocationCompiler` | Private exchange-independent recipe and separately constructed safe descriptor | Adapter semantics, process execution, or plan redaction as descriptor construction |
| Carrier/plan finalizer | Exchange-bound payload, carrier handle, and final immutable execution plan | Changing the selected executable, profile, cwd, environment, or policy |
| Execution backend | Verbatim execution of the final private plan | Client semantics, ambient environment merging, or policy interpretation |
| `TranscriptStore` | Ledger route, exchange IDs, acceptance, descriptor persistence, terminal indexes, and accepted-descriptor copying | Request cwd selection or native identity inference |
| `MediatedTurnService` | Lifecycle ordering and terminalization of every accepted turn | Configuration authority or receiver-native fact invention |

- Public `application` is a registry selector, not provenance.
- CLI flags are deterministic compiled output, not an independent authority.
- Unknown native application, model, conversation, or turn identities remain
  absent. Selected application and preflight version never fill missing native
  evidence.

## Configuration and version authority

- Startup loads a complete immutable snapshot. Invalid present configuration
  fails atomically; a missing optional host binding yields typed unavailability.
- JSON Schema/JSON is the first provider, not a permanent domain dependency.
- Integration `supported_versions` and host `expected_version` are optional
  pins. Omission means launch the current resolved executable.
- Adapter `verified_versions` is an evidence label for the dialect that was
  checked. It is not a launch gate and does not reject receiver-native versions.
- An explicit host pin may only narrow a declared integration list. It cannot
  invent a version the integration forbade. Adapter evidence never participates
  in that check.
- Preflight-observed executable version is launch evidence only. A version
  probe fails before acceptance only when an explicit pin missed.
- `exchange.application.id/version` requires an explicit mapping from correlated
  receiver-native evidence. If both preflight and native versions exist and
  disagree, the accepted turn fails with
  `NATIVE_APPLICATION_VERSION_MISMATCH`.
- Live-verified claims name the observed version. They do not require a
  configuration bump.
- AGY remains fail closed until its profile is independently evidenced.

## Policy lattice

- Every security field declares an explicit partial order.
- The effective ceiling is the intersection of package and host ceilings.
- Host defaults must fit that ceiling. Session and per-operation controls may
  only narrow it.
- Unsupported mappings, widening, ambiguity, and incomparable values reject;
  they are never silently clamped.
- Tool sets use intersection. Access uses `none < read < write`. Boolean fields
  declare which polarity is narrower.
- `policy.session_sha256` binds the stable lane policy. An
  `effective_sha256` may differ only through allowed per-operation narrowing.
- Digests use versioned canonical semantic JSON and exclude host paths, secret
  material, source identifiers, and probe output.

## Environment and secret boundary

- Managed compilation starts from an empty map plus explicitly declared
  platform/client inheritance.
- The private plan contains the complete child environment. Backends pass it
  verbatim and never merge `process.env`.
- Environment names match `^[A-Za-z_][A-Za-z0-9_]*$`; values are well-formed
  strings without NUL.
- Windows name comparison is ASCII case-insensitive. A `Path`/`PATH` collision
  within or across layers rejects even when values match. The integration
  profile's canonical spelling is preserved.
- Explicit unset is a tombstone. It may remove only a declared optional value;
  required unsets and later restoration reject as widening.
- The first provider supports named `process_env` sources. Host-local bindings
  map opaque source IDs to ambient names. Literal secrets in package/session JSON
  are forbidden; file and keychain providers remain future implementations.
- Sources resolve once into the runtime-only plan. Variable names, source IDs,
  and values never enter safe descriptors or policy digests.
- Para-agent guarantees only that framework-originated secret values do not
  enter argv, descriptors, receipts, public errors, logs, snapshots, fixtures,
  or generated test output.
- Accepted prompts and receiver-native content, including raw traces, normalized
  records, and final replies, are privileged untrusted content. They remain
  exact and cannot promise redaction if a caller or client emits a secret.
- This boundary is structural containment, not end-to-end data-loss prevention.

## Workspace, cwd, transcript route, and lane binding

- A server-owned workspace root and handle-derived ledger session select the
  transcript store. Request `cwd` never changes that route.
- Managed `cwd` is a logical relative selector within a configured workspace;
  omission selects its root. The host binding resolves it to both a canonical
  physical directory and a stable non-path `working_directory_id`.
- Reject absolute/rooted, drive-relative, UNC/device, NUL, empty-segment, `.`,
  and `..` forms.
- Every component must be an existing physical directory. Symlink, junction,
  mount-point, or other reparse traversal rejects even when it resolves inward.
- The final canonical path is private plan data. Descriptors contain only
  `workspace.id` and `working_directory_id`.
- Each v2 conversation lane binds durably to:
  - application selector;
  - adapter `{ id, version, profile_id }`;
  - integration `{ id, revision }`;
  - session profile `{ id, revision }`;
  - workspace `{ id, working_directory_id }`; and
  - `policy.session_sha256`.
- `TranscriptStore.acceptExchange()` compares this binding inside its writer
  lane with every prior v2 acceptance for the conversation key. Any difference
  fails before acceptance with `CONVERSATION_BINDING_CONFLICT`.
- Binding is launch context, not native resume/session continuity. A caller uses
  a new handle/ledger for a new context.

## Private recipe, final plan, and safe descriptor

- Before acceptance, the compiler produces a deeply immutable
  exchange-independent recipe and descriptor basis. The safe descriptor is
  finalized only after readiness contributes its allowlisted facts.
- After acceptance, the finalizer may fill only declared runtime slots such as
  store-owned `exchange_id` and an opaque carrier handle/path. It cannot change
  any selected authority or descriptor fact.
- The final private plan may contain executable path, argv, canonical cwd,
  resolved environment values, prompt bytes, carrier path, stdio routing, and
  cleanup handles. It is never serialized into public or durable output.
- The safe descriptor is built directly from allowlisted semantic facts. It is
  never obtained by serializing or redacting the private recipe/plan.

Closed descriptor shape:

```text
invocation_descriptor: {
  descriptor_version: 1,
  integration: { id, revision },
  adapter: { id, version, profile_id },
  surface,
  mode,
  session_profile: { id, revision },
  workspace: { id, working_directory_id },
  policy: { session_sha256, effective_sha256 },
  carrier: { kind },
  stdio: { prompt, semantic, diagnostic },
  readiness: { <dimension>: { state, evidence_kind, ...safe_facts } }
}
```

- The descriptor contains no executable path, argv, cwd, environment name or
  value, secret/source reference, raw probe output, PID, carrier path, or host
  topology.
- Acceptance stores the descriptor. Terminal persistence receives a store-owned
  copy from acceptance; callers cannot independently supply it.
- Scanner, assembler, receipt, idempotency, lane-binding, and commit validation
  compare the descriptor exactly using canonical semantic JSON.

## Readiness contract

Each dimension reports `passed | failed | unknown | not_applicable`, an evidence
kind, and the integration-profile revision:

- `executable`
- `version`
- `configuration`
- `authentication`
- `capabilities`
- `environment_sources`
- `environment_exact`
- `workspace`
- `prompt_carrier`
- `backend`

- A plan is ready only when every profile-required dimension is `passed`.
- `unknown` is allowed only for dimensions the profile does not require.
- Required-but-unknown yields `READINESS_PROOF_INSUFFICIENT` before acceptance.
- Each probe has a timeout, bounded output, a strict parser, and an allowlisted
  safe projection. Raw output remains private diagnostics.
- Configuration inspection proves only observed configuration/discovery facts
  for the exact process environment and cwd. It does not prove authentication,
  network/model availability, capability enforcement, MCP non-startup, or
  sandbox enforcement.
- Readiness version never becomes receiver-native application provenance.

## Prompt carriers

- Prompt content never enters argv. Prefer stdin when the profile evidences exact
  consumption; use a file only when its exact consumption is evidenced.
- Adapter encoding is exchange-bound because structured protocols may embed the
  store-owned `exchange_id`. Carrier handling is therefore two-phase:
  - pre-acceptance: validate the carrier recipe, root, permissions, capabilities,
    cleanup support, and exchange-independent resources;
  - post-acceptance: adapter-encode exact bytes, materialize the carrier, and
    finalize the private plan.
- A post-accept encoding/materialization failure invokes no native client and
  durably terminalizes the accepted turn as failed with
  `native_stop_confirmed: true`.
- Valid prompt strings must be well-formed Unicode and round-trip as exact UTF-8.
- A file carrier uses a host-supplied private physical runtime root with no
  reparse traversal. POSIX requires directory `0700` and file `0600`; Windows
  requires a validated host-approved DACL without a broad read/modify principal.
- Use an opaque random name, exclusive `wx` creation, complete buffered write,
  sync, close, and digest/length readback before execution.
- Only the private plan may contain the unavoidable file path.
- Cleanup begins after confirmed native close on success, failure, timeout, and
  cancellation. Windows lock failures receive bounded retry. Unresolved deletion
  is reported as the non-terminal warning `PROMPT_CARRIER_CLEANUP_PENDING`.
- Startup scavenging uses a lock, fixed name grammar, ownership/age/lease checks,
  no link following, and individual non-recursive deletion. Fresh, active,
  unknown, linked, or locked entries remain untouched.

## Lifecycle and acceptance boundary

The exact order is:

1. Validate request identity and derive the exact conversation key.
2. Resolve the fixed handle-owned mediation-ledger route; ignore request cwd for
   transcript selection.
3. Open/scan the store, complete mandatory recovery, read recovery notices, and
   restore durable quarantine into the process gate.
4. Acquire the conversation gate; active or quarantined lanes reject.
5. Pin one immutable configuration snapshot.
6. Resolve registry, session profile, workspace/working-directory identity,
   policy intersection, and prospective lane binding.
7. Compile the private recipe and separate safe-descriptor basis.
8. Run bounded readiness, validate all exchange-independent carrier,
   environment, cwd, backend, and trace resources, then finalize the safe
   descriptor from allowlisted facts. Failure cleans resources and releases the
   gate with no acceptance.
9. Durably accept the descriptor. The store allocates `exchange_id` and rechecks
   lane binding inside its writer lane.
10. Bind the gate lease to that exchange ID and initialize trace capture.
11. Adapter-encode and materialize the exchange-bound carrier; finalize the plan.
12. Execute, capture separate semantic stdout and diagnostic stderr, project
    native evidence, and durably commit exactly one terminal exchange and marker.
13. Attempt carrier/resource cleanup without rewriting the terminal outcome.
14. Construct MCP egress only after terminal durability, then release or
    quarantine the lane according to commit state and confirmed native stop.

- Only failures supported by a completed preflight are guaranteed to occur
  before acceptance.
- Every accepted turn terminalizes exactly once, including carrier/finalization
  failures before native invocation.
- Idempotent replay resolves against durable state before creating a second
  carrier or native invocation.

## Persistence dialect and v1 transition

One immutable row-0 header pins one persistence dialect.

- Preserve all v1 schemas and validators unchanged.
- Add v2 header, transcript-exchange, acceptance, terminal-marker, and required
  reconciliation/recovery row variants.
- New ledgers write a v2 header and v2 rows only.
- Existing v1 ledgers remain fully readable/queryable and eligible for mandatory
  same-dialect pending-acceptance recovery, missing-marker repair, and quarantine
  reconciliation.
- New normal acceptance into a v1 ledger fails before acceptance with
  `TRANSCRIPT_UPGRADE_REQUIRED`.
- Never append v2 normal rows under a v1 header, rewrite/reinterpret a v1 header,
  or continue new v1 work without descriptors.
- A caller needing new work selects a new mediation-ledger session/handle. A
  different pane suffix is insufficient where routing normalizes to the same
  session.
- A chained segment or offline upgrade is deferred until cross-segment ordering,
  indexes, digests, recovery, and quarantine rules are separately frozen.
- “Dual read/write” means dual-read across v1 and v2 ledgers, v2-only new normal
  writes, and same-dialect writes solely for mandatory legacy recovery/admin.

V2 acceptance and terminal exchange/marker persist the same safe descriptor.
The store copies it from acceptance and verifies exact equality. V1 scrutiny
returns legacy rows without fabricating a descriptor or lane binding.

## Backends, diagnostics, and public errors

- Process backends pass the plan environment exactly and keep semantic stdout
  separate from diagnostic stderr.
- Raw native bytes may be persisted only as privileged exact evidence.
- Managed mux rejects secret-classified sources before invoking mux and remains
  unavailable with `CLIENT_ENV_ISOLATION_UNPROVEN` until a fresh isolated
  namespace/server proves a compiled nonsecret control environment and pane
  inheritance.
- Existing shell/raw program panes remain explicitly unsafe console surfaces and
  create no mediated exchanges.
- Public errors use fixed code/message templates and allowlisted safe facts.
  Paths, argv, environment, raw OS errors, stdout, stderr, and private plans are
  never interpolated. Redaction is defense-in-depth, not serialization authority.

Public envelope:

```text
error: {
  code,
  phase: pre_acceptance | accepted | post_commit,
  retryable,
  message,
  safe_details?
}
receipt?  // present only after durable acceptance and terminalization
```

Frozen failure vocabulary:

- Registry/policy: `CLIENT_UNKNOWN`, `CLIENT_UNAVAILABLE`,
  `CLIENT_CONFIG_INVALID`, `INTEGRATION_ADAPTER_INCOMPATIBLE`,
  `SESSION_PROFILE_UNKNOWN`, `CLIENT_POLICY_WIDENING`,
  `CLIENT_POLICY_UNSUPPORTED`, `CLIENT_POLICY_AMBIGUOUS`.
- Environment/backend: `CLIENT_ENV_NAME_INVALID`,
  `CLIENT_ENV_CASE_COLLISION`, `CLIENT_ENV_SOURCE_MISSING`,
  `CLIENT_ENV_SOURCE_INVALID`, `CLIENT_ENV_REQUIRED_UNSET`,
  `CLIENT_ENV_SECRET_UNSAFE_BACKEND`, `CLIENT_ENV_ISOLATION_UNPROVEN`.
- Workspace/lane/store: `CLIENT_WORKSPACE_UNKNOWN`, `CLIENT_CWD_INVALID`,
  `CLIENT_CWD_MISSING`, `CLIENT_CWD_NOT_DIRECTORY`, `CLIENT_CWD_ESCAPE`,
  `CLIENT_CWD_REPARSE`, `CONVERSATION_BINDING_CONFLICT`,
  `TRANSCRIPT_UPGRADE_REQUIRED`, plus existing busy/quarantine codes.
- Readiness: `READINESS_EXECUTABLE_UNAVAILABLE`,
  `READINESS_VERSION_UNSUPPORTED`, `READINESS_CONFIGURATION_FAILED`,
  `READINESS_AUTHENTICATION_FAILED`, `READINESS_CAPABILITY_UNAVAILABLE`,
  `READINESS_TIMEOUT`, `READINESS_MALFORMED`,
  `READINESS_PROOF_INSUFFICIENT`.
- Carrier: `PROMPT_CARRIER_UNSUPPORTED`, `PROMPT_CARRIER_ROOT_UNSAFE`,
  `PROMPT_CARRIER_CREATE_FAILED`, `PROMPT_CARRIER_WRITE_FAILED`,
  `PROMPT_CARRIER_VERIFY_FAILED`, `PROMPT_CARRIER_CLEANUP_PENDING`,
  `PROMPT_CARRIER_SCAVENGE_FAILED`.
- Accepted execution: `PROMPT_ENCODING_FAILED`,
  `PROMPT_CARRIER_MATERIALIZATION_FAILED`, `INVOCATION_PLAN_INVALID`,
  `NATIVE_APPLICATION_VERSION_MISMATCH`, and the existing typed
  `NATIVE_TRANSPORT_*`, `NATIVE_FRAME_*`, and `NATIVE_CORRELATION_*` families.

Pre-accept failures have no receipt. Accepted-phase failures terminalize once.
Post-commit cleanup/result-construction failures carry the already committed
receipt and never rewrite, duplicate, or re-execute the exchange.

## Public surfaces

- `delegate` retains existing fields and adds optional `cwd` and
  `sessionProfile` selectors.
- It accepts no arbitrary executable, argv, environment, secret, policy-ceiling,
  or credential fields.
- `spawn` becomes a strict tagged union of existing shell pane, existing raw
  command pane, and managed `application + sessionProfile` pane. Mixed shapes
  reject; fields are never silently ignored.
- Managed panes are console surfaces and create no mediated rows.

## Verification gates

- Strict schema compilation and cross-dialect rejection for every v1/v2 row.
- Fake-client registry/provider tests, immutable snapshots, version-intersection
  failures, and no client-specific branches in generic services.
- Full policy widening/incomparability matrix and deterministic digest/plan
  fixtures.
- Exact environment tests: insertion order, Windows case collisions, unset,
  parent immutability, and no backend ambient merge.
- Secret sentinels absent from every framework-generated/public channel while
  client-emitted sentinels remain exact only in privileged native content.
- Real Windows inward/outward junction witnesses with no silent skip.
- Exact carrier bytes, protection checks, `wx`, cleanup across all outcomes,
  locked-file retention/retry, concurrent scavenging, and malicious link/name
  preservation.
- Ordering witness: recovery before gate; preflight creates no acceptance;
  post-accept carrier failure terminalizes once without native invocation.
- V1 read/recovery/admin, v1 new-accept rejection, v2 new-ledger writes,
  descriptor copy/equality, durable lane binding, and idempotency.
- Every new suite is named in `mcp/tests/para-agent/test-manifest.json`; the
  manifest runner, not discovery globs, is bounded authority.

## Explicit Windows proof status at freeze

- Exact child-environment enforcement is `unknown` in the restricted Codex
  environment and requires a separate unsandboxed Windows gate.
- Prompt-file DACL enforcement, Windows lock retry, crash scavenging, and real
  junction/reparse containment are unimplemented/unverified.
- Current workspace transcript/trace ACL inheritance permits broader local
  access than a confidentiality or immutability claim allows.
- Windows `read-only` client sandbox enforcement remains unverified. It is
  defense-in-depth only until an independent witness exists.
