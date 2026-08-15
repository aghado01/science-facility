# Para-agent decision canon

Living document — states what is decided **now**, corrected in place as decisions evolve.
Completed work is recorded in [ledger.md](ledger.md); everything ahead in [roadmap.md](roadmap.md).

**Authority rule (standing).** The frozen contracts under
[`mcp/para-agent/contract/`](../../../mcp/para-agent/contract/) are canon for *design*:
[MEDIATED-EXCHANGE-CONTRACT.md](../../../mcp/para-agent/contract/MEDIATED-EXCHANGE-CONTRACT.md),
[CONSOLE-CONTRACT.md](../../../mcp/para-agent/contract/CONSOLE-CONTRACT.md), and
[CLIENT-INTEGRATION-CONTRACT.md](../../../mcp/para-agent/contract/CLIENT-INTEGRATION-CONTRACT.md).
This file records *rulings, rationale, and supersessions* and **never restates a contract rule**.
Where a decision changes behaviour, the contract is edited and cited here — not paraphrased.
Restating contract rules in planning prose is what produced the 2026-08-15 drift (P15).

Arguments and evidence live in [../notes/](../notes/) (founding intent:
`sol-client-loading.md`, `sol-transcript-drafting.md`), [../reports/](../reports/) (point-in-time
reports and historical plans), and [../discussions/](../discussions/) (chat logs).

Status vocabulary: **ruled** = explicit owner ruling; **carried** = adopted by owner approval of a
plan, open to re-ruling item-by-item; **landed** = in code at the cited commit; **OPEN** = awaiting
ruling or evidence.

## Doctrine (standing)

- **Asymmetric authority.** The ingress prompt is authoritative at MCP admission. Observed
  application, model, native identity, exposed reasoning, tools, and terminal reply are
  authoritative only from correlated receiver-native evidence. Unknown facts stay **absent** —
  never backfilled from the selector or from preflight.
- **Composable axes, not combinations.** Surface policy, shell profile, application adapter, host
  environment binding, and invocation receipt are independent axes. Never one profile per
  client × shell × application (P5).
- **Invocation mode is explicit.** Owned by para-agent, never inferred from ambient shell
  behaviour or TTY detection.
- **No post-hoc inference.** Console/pane activity never implies a mediated exchange. Exchange
  boundaries are declared at admission, never reconstructed afterward.
- **Evidence is not a gate.** Version labels, fixtures, and probe records are evidence of what was
  checked. Only explicit pins gate launch (P6).
- **Proof limits are stated.** `unknown` stays `unknown`. A probe proves exactly what it observed,
  for the exact process environment and cwd it observed it in.
- **Fail closed.** Unsupported, ambiguous, or widening mappings reject; they are never silently
  clamped or ignored.
- **Nu is a provider.** Strict, replaceable, beneath typed semantics. It owns no schema, storage,
  provenance, or public query semantics.

## Decisions

| # | decision | status |
|---|---|---|
| P1 | Para-agent owns a third mediated transcript, distinct from the Console Journal, with asymmetric prompt/receiver authorities | ruled 2026-08-13 ([sol-transcript-drafting](../notes/sol-transcript-drafting.md)); landed |
| P2 | A distinct typed `delegate` owns one mediated prompt/reply transaction; `run`/`send`/`wait`/`read`/`exec` are console escape hatches and never acquire inferred exchange boundaries | ruled; landed |
| P3 | Persistence dialect is JSON Schema 2020-12 with Ajv 8 + `ajv-formats` as direct dependencies; composed variants close with `unevaluatedProperties: false`, never subtype-local `additionalProperties: false` | ruled 2026-08-14 (Fable W0 sharpening — the pre-remediation exchange schema was *unsatisfiable*, not merely drifted); landed |
| P4 | The manifest-driven runner is bounded authority — not discovery globs, not prose. It emits `SUITE-ABORTED` on terminating errors and fails on zero discovery, suite mismatch, nonzero child exit, or missing terminal summary | ruled 2026-08-14 (Fable; carried from the reposnapshot false-green experience); landed |
| P5 | Client handling decomposes into five composable axes: surface policy, shell profile, application adapter, host environment binding, invocation receipt | ruled 2026-08-14 ([sol-client-loading](../notes/sol-client-loading.md)); codified in CLIENT-INTEGRATION-CONTRACT §Authority model |
| P6 | **Version authority.** Integration `supported_versions` and host `expected_version` are *optional* pins; omission launches the resolved executable. Adapter `verified_versions` is an evidence label, not a launch or projection gate. Live-verified claims name the observed version and require no configuration bump | **ruled 2026-08-15**; landed `cbce45a`. Supersedes the earlier rule that Claude needed fresh `2.1.232` evidence *or* a pinned `2.1.226` executable before live compatibility could be claimed |
| P7 | Prompt content never enters argv. Stdin preferred where exact consumption is evidenced; file carriers require a private runtime root, verified modes/DACL, exclusive creation, sync/readback, opaque names | ruled; partially landed (Windows DACL, lock retry, and scavenging unverified — see roadmap) |
| P8 | The safe invocation descriptor is built directly from allowlisted semantic facts — never by serializing or redacting the private plan | ruled; landed |
| P9 | One immutable row-0 header pins one persistence dialect. New ledgers write v2 only; v1 ledgers stay readable and eligible for same-dialect recovery but reject new acceptance with `TRANSCRIPT_UPGRADE_REQUIRED` | carried; **not yet landed** (substrate-migration track) |
| P10 | **Grok managed mediation is no-go** until tool isolation is evidenced. Exact unsandboxed inspection found four inherited stdio MCP definitions while `mcp list --json` returned empty; no no-load/no-start control is proven, and `grok inspect --json` is configuration-only evidence | ruled 2026-08-15 (W0-B); reopen only on the conditions in [grok-1.0.4-wave0-evidence](../reports/grok-1.0.4-wave0-evidence.md) |
| P11 | **Grok is the extensibility acceptance test, not a delivery wave.** Onboarding Grok through profiles/codecs alone — with zero changes to generic services — *is* the proof the substrate works. The isolation probe (P10) has no code dependency and runs independently of the migration | **ruled 2026-08-15**; supersedes the Wave-3-then-Wave-4-C sequencing in the historical client-integration plan |
| P12 | AGY remains fail-closed until its profile is independently evidenced by a fresh native stream capture. The stale architecture report is not evidence of AGY correctness | ruled; standing |
| P13 | `application` is a public registry selector, not provenance. CLI flags are deterministic compiled output, not a fifth authority | ruled; landed |
| P14 | Managed mux rejects secret-classified sources and stays unavailable with `CLIENT_ENV_ISOLATION_UNPROVEN` until isolated control-environment and pane inheritance are evidenced. Raw `spawn`/`exec` remain legacy escape hatches outside the managed guarantee | ruled; landed |
| P15 | **Planning canon lives here.** `planning/` holds decisions + roadmap + ledger; `briefs/` holds small runstamped per-chip guidance with the report appended; `reports/` holds point-in-time reports and superseded plans; `discussions/` holds chat logs. No planning document restates a contract rule, carries a status ledger, or embeds its own historical audit | **ruled 2026-08-15** (this cleanup) |
| P16 | Verification counts are never hand-copied into prose as standing claims. The ledger records a count *with the commit it was observed at*; the runner is the authority | **ruled 2026-08-15**. The W1 entry's `216` was written before `cbce45a` landed and was stale within hours; the true figure at `8fe3643` is `218` |
| P17 | `NATIVE_APPLICATION_VERSION_MISMATCH` — implement or demote. It is defined in `errors.js:50` and specified in CLIENT-INTEGRATION-CONTRACT §Configuration and version authority, but has **zero throw sites and zero tests**. Under P6 it is now the only remaining version check on the live path, and it is specified as a *post-acceptance* failure — so version disagreement kills an accepted turn rather than failing preflight | **OPEN — decide before the migration lands** |
| P18 | Golden-plan determinism. `finalizeInvocationDescriptor` embeds the readiness facts, including `readiness.version.version`. Under P6 that field is machine-dependent, while the contract requires exact descriptor comparison and deterministic plan fixtures. Goldens must either inject synthetic readiness or normalize the version fact — undecided which | **OPEN — blocks the migration's golden-plan gate** |
| P19 | Egress construction: whether it stays purely post-commit inside the returned receipt, or needs a separately durable post-commit record | OPEN (carried unresolved from the remediation release gates) |
| P20 | Windows proof gaps: exact child-environment enforcement, prompt-file DACL, lock retry, crash scavenging, and real junction/reparse containment are unimplemented or unverified, and current transcript/trace ACL inheritance does not support a confidentiality or immutability claim | OPEN; standing honesty constraint on release language |

## Superseded

- **Version authority before P6** — that adapter `verified_versions` must intersect with
  integration `supported_versions` at registry validation, and that Claude required fresh
  `2.1.232` evidence or a genuinely pinned `2.1.226` executable. Retired 2026-08-15.
- **Grok as Wave 3** of a five-wave client-integration sequence, with the extensibility proof
  as a separate Wave 4-C item. Retired by P11.
- **Wave 0–4 numbering**, which collided across the two historical plans (both numbered 0–4, with
  different meanings for every number). Retired by P15 in favour of named tracks.
