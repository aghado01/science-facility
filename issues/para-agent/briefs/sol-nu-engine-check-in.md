Status

| Area | State |
|---|---|
| Architecture | Console and mediated evidence planes remain separate; frozen continuation contract implemented |
| Vertical slice | `delegate` → adapter → native client → raw trace → assembler → durable terminal commit → return-only egress is MCP-wired |
| Provenance | Live-stream only; no selected-application or model fallback laundering |
| Clients | Claude 2.1.226 and Codex 0.147.0 captured-stream conformance verified; AGY remains fail-closed/unverified |
| Guidance | Primary skill and examples match live MCP schemas, including read-only quarantine inspection |
| Bounded verification | 17 suites, 165/165 passed; 0 failed, skipped, cancelled, or aborted |
| Live verification | Exact-current isolated Windows gate passed 2/2; 0 failed, skipped, or cancelled |

The continuation now matches the intended transaction boundary: the assembler holds the transaction open until the complete receiver-authoritative final reply or terminal outcome exists. The store then file-syncs the terminal row before its terminal marker and returns those exact persisted authorities. Only afterward is MCP egress constructed as return-only evidence; persisted `delivery` never contains egress.

Quarantine recovery is likewise closed. Missing-marker repair creates durable, restart-visible ambiguous-commit evidence. Ordinary MCP exposes only read-only `quarantine_status`. Mutation is isolated in the disabled-by-default offline `para-agent-quarantine` CLI, requires the exact current tuple and an admitted evidence basis under the transcript's exclusive writer lease, has no force path, and makes identical retries idempotent.

The authoritative bounded gate passed 17 suites / 165 tests, including regressions that reject whitespace aliases and ill-formed Unicode before gate or transcript routing. The exact-current live Windows gate then passed 2/2 against Nu 0.114.1, psmux 3.3.7, and Claude 2.1.226. Its first sandboxed substrate attempt timed out starting a detached ConPTY while the Claude pilot passed; the identical isolated rerun outside the sandbox passed both tests.

AGY remains a client-conformance item rather than a release blocker for the verified clients. The post-checkpoint probe found AGY 1.1.13 but produced zero native-stream bytes and surfaced an authentication-wait timeout. Operator diagnosis now points to an AGY launch/configuration problem — possibly specific to launching through Nu — rather than an authentication failure; the timeout is recorded only as the observed symptom. No fixture, transport capability, or model identity was inferred, and no repeat launch was attempted pending that investigation.

Remaining work

- Resolve the AGY launch/configuration issue, capture a fresh native stream, conform a version-labelled fixture, and pass its real-client pilot before enabling the adapter.
- Keep public `delegate` idempotency unsupported until retries can suppress duplicate native execution.

The execution record is in [sol-remediation-swarm-plan.md](../reports/sol-remediation-swarm-plan.md), with the boundary in [MEDIATED-EXCHANGE-CONTRACT.md](../../../mcp/para-agent/contract/MEDIATED-EXCHANGE-CONTRACT.md).

Original mediated slice: `2672376`; frozen continuation contract: `62ec0dc`; terminal durability, quarantine, and runner hardening: `4230cc5`. The earlier foundation is `37383a6`. No push was performed by this campaign.

# Additional note

the 2/2 live Windows gate (isolated psmux + real Claude mediation) passed before those final audit-hardening changes landed, so live recertification against the exact current checkpoint is intentionally still pending. That's the main thing standing between "verified in tests" and "verified end-to-end on current source."

Resolution (2026-08-14): this note records the handoff state. The exact-current isolated gate has now been rerun and passed 2/2 with no failures, skips, or cancellations.
