# Review notes — context-mode-nexus-post-mortem-and-remediation-plan.md

Date: 2026-07-25. Reviewer pass: read plan in 4 chunks, cross-examined against
`utils/context-mode-core`, `packages/context-mode` (upstream), and sibling reports
under `issues/`.

## 1. Evidence-citation verification

Every citation in the plan's Evidence Index was checked. All are substantively
accurate; line numbers drift by 1–5 in places but never point at the wrong thing.

| Plan claim | Cite | Verdict |
| --- | --- | --- |
| Adapter registry = Codex only | `adapters/index.mjs:1-16` | CONFIRMED exact |
| Default-all deploy targets | `lib/deploy-contract.mjs:1-23` | CONFIRMED (`return new Set(DEPLOY_TARGETS)` at :18) |
| Runner sets platform/storage pre-init | `runtime/mcp-runner.mjs:9-24` | CONFIRMED (:22-23) |
| Direct bundle launch | `runtime/mcp-runner.mjs:37-41` | CONFIRMED exact |
| PID fallback | `runtime/lib/custom-routing.mjs:137-141` | CONFIRMED; actual fn 135–143, fallback at :141. **Second PID fallback at :180 not cited** |
| Cross-client admin roots | `infrastructure.json:44-72` | CONFIRMED (block is 44–73) |
| Unconditional infra context renderer | `lib/infrastructure.mjs:187-203` | CONFIRMED (fn 187–204) |
| SessionStart injection | `runtime/lib/native-runner.mjs:193-219` | CONFIRMED (fn 193–220) |
| Inline client deploy branches | `deploy.mjs:330-454` | CONFIRMED (`configureClaude` starts :325) |
| Antigravity shared-config pinned to CLI + 2 guessed configs | `deploy.mjs:625-630` | CONFIRMED exact |
| Composite package scripts | upstream `package.json:82-101` | CONFIRMED: `prepublishOnly: npm run build`, no `prepack`/`prepare`, `postinstall: node scripts/postinstall.mjs` |
| Claude-specific dependency postinstall | upstream `scripts/postinstall.mjs:110-232` | CONFIRMED: installed_plugins.json heal (:118-133), settings.json heal (:144-153), plugin.json heal (:158-165), symlink/junction for stale registry (:207-232) |
| Claude registry/cache/startup repair | upstream `start.mjs:137-410` | CONFIRMED: Layers 1/3/4/5b, deploys `~/.claude/hooks/context-mode-cache-heal.mjs` and registers it in `~/.claude/settings.json` SessionStart (:291-415) |
| MCP latest-session attribution | upstream `src/server.ts:440-460` | CONFIRMED: `currentAttribution()` → `CLAUDE_SESSION_ID ?? resolveSessionIdFromSessionDB()` |
| Mid-session Claude cache heal | upstream `src/server.ts:850-890` | CONFIRMED: `healCacheMidSession()` called from `trackResponse()` on first tool call |
| PID-keyed stats | upstream `src/server.ts:991-1015` | CONFIRMED: `getStatsFilePath()` → `CLAUDE_SESSION_ID \|\| pid-${ppid}` |
| Latest-row conversation stats | upstream `src/server.ts:3994-4007` | CONFIRMED: `ORDER BY created_at DESC LIMIT 1` |
| Source HEAD `370db6eb...` | — | CONFIRMED exact (git rev-parse) |
| 51 qualified upstream failures | `node/BUILD.json` | CONFIRMED (4637 pass / 51 fail / 57 skip; central 57/0) |

## 2. The plan's strongest and correct core

- Plane separation (hook = conversation identity; MCP connection ≠ conversation) is
  the load-bearing insight and is correct per MCP spec and observed client behavior.
- "Missing identity → explicit unbound, never a guess" is the right rule.
- Control plane / data plane split is the right frame for the mutation vectors found.
- Claude-last migration order is right; its ablated state is the clean baseline.
- Antigravity analysis is the sharpest section: shared native global at
  `~/.gemini/config/mcp_config.json` written with `--client antigravity-cli` +
  `CONTEXT_MODE_DIR=~/.gemini/antigravity-cli/context-mode` is confirmed verbatim.

## 3. Findings the plan misses or understates

### 3A. (Major) The nexus itself aims upstream's Claude repair at real `~/.claude`
- `clients/claude.json`: `upstreamPolicySource: "client-native"`, `upstreamPolicyRoot: "~/.claude"`.
- `lib/upstream-policy.mjs:45-52`: for `client-native`, sets `env.CLAUDE_CONFIG_DIR = upstreamPolicyRoot`.
- `runtime/mcp-runner.mjs:19` passes that env into the spawned `server.bundle.mjs`.
- Upstream `healCacheMidSession` uses `resolveClaudeConfigDir()` which honors
  `CLAUDE_CONFIG_DIR` (comment cites Issue #460 round-3).
- ⇒ On the **first tool call of every Claude MCP session**, the long-lived server can
  `unlinkSync` a dangling symlink and `symlinkSync`/junction under
  `~/.claude/plugins/cache` — a runtime mutation of watched Claude plugin state,
  delivered by nexus-supplied configuration.
- Conversely, non-Claude clients get `core-default` → `CLAUDE_CONFIG_DIR` = a
  context-mode-owned policy dir → `installed_plugins.json` absent → heal returns early.
- **This asymmetry explains the observed Claude-rotates / Codex-stable split**, which
  the plan reports as an observation without a mechanism. It is also a single-variable,
  cheap ablation (repoint Claude's `CLAUDE_CONFIG_DIR`) that is *not* in Phase 1's arms.
  Should be Hypothesis #1.

### 3B. Existing mitigations under-credited → mis-prioritized phases
- `deploy.mjs:46,590-598` — **dry-run is already the default**; `--apply` required.
  Phase 5's "make the default read-only" is largely done. Real defect is narrower:
  `--apply` with no `--target` = all four clients. One-line fix in `parseDeployTargets`.
- `runtime/lib/client-config.mjs:78-82` — already **enforces** `server.bundle.mjs` only,
  with an explicit error naming the start.mjs bypass. Plan calls this "a partial
  mitigation" without noting it is a guarded, tested invariant.
- `runtime/lib/client-config.mjs:37-46` `resolveClientId` — Antigravity surface detection
  from hook input already exists. So the plan's option (2) partly exists on the hook
  plane; option (2) on the *MCP* plane is impossible by the plan's own protocol
  analysis. The plan should just decide for option (1), one family-shared store.

### 3C. (Major) No "stop the bleeding" tier; Phase 2 blocks everything
Phase 2 = fork/extract upstream (315 files, 11 tools, 4.6k tests) and nothing in
Phases 3–6 can start until it lands. But the highest-value fixes are all nexus-local:
1. `--target` mandatory for `--apply` (`lib/deploy-contract.mjs:18`).
2. Split capability sources: `buildCoreDefaultPolicy` (`lib/upstream-policy.mjs:15-24`)
   and `infrastructureContext` (`lib/infrastructure.mjs:187-204`) both call
   `infrastructurePermissionPatterns`, which merges `filesystemPolicy` **and**
   `administrationPolicy`. Restricting them to `filesystemPolicy` kills systemic
   defects #6 and #7 and the "Codex grants every task write to .claude/.cursor/
   .codex/.gemini" finding from the codex report — few lines.
3. Delete the `pid-${ppid}` fallbacks at `custom-routing.mjs:141` **and `:180`**;
   return null / unbound.
4. Repoint Claude's `CLAUDE_CONFIG_DIR` off `~/.claude` (also = ablation 3A).
5. `npm install --ignore-scripts` in `node/`.
Recommend an explicit Phase 1.5 for these.

### 3D. `--ignore-scripts` never named
Phase 2 action 6 states the principle but not the available mechanism, which works
against the *current* tar with no fork. Trap worth spelling out: `--ignore-scripts`
also suppresses the wrapper's own `node/package.json` postinstall
(`apply-context-mode-patches.mjs`), so that must then be invoked explicitly.

### 3E. The 51 failures need triage, not just a gate
BUILD.json's qualification is specific and environmental: missing Git Bash/Python/Rust
PATH entries, git metadata excluded from the clean archive, Windows symlink privileges.
The plan's gate ("zero unexpected failures OR named waivers with owner + expiration")
is right in principle but reads as an unpathed blocker. Actionable form: classify the
51 into (a) provision the toolchain in the pinned build env, (b) genuinely N/A on
Windows → permanent documented waiver, (c) real defects.

### 3F. Phase 1 matrix is unprioritized and misses the hook plane
9 arms × 12 lifecycle cases × 4 clients with no ordering. Suggested order by prior:
CLAUDE_CONFIG_DIR (3A) → dependency postinstall → residual plugin state → rest.
Missing axis: the hook plane. `deploy.mjs:366-381` registers six Claude hook events;
`native-runner.mjs:248-255` spawns a `node` child per hook event (20s timeout, 4MB
buffer) writing under `~/.claude/context-mode`. Per-tool-call subprocess storm is the
other thing that changed at the same time and has no lifecycle case.

### 3G. Small factual corrections
- `ctx_insight` classified as administrative; it is arguably a data-plane read.
  Affects what Phase 2 removes.
- Proposed layout puts `packages/` inside `context-mode-core` while upstream source
  already lives at `D:\aghado01\packages\context-mode`. Two `packages/` roots — rename.
- "No default adapter; unknown detection must stop with a diagnostic" needs a
  plane-scoped qualifier. Re-anchored on code rather than on ARCHITECTURE.md: hooks
  fail open *in the implementation* — `native-runner.mjs:222-229` returns `noOp()` on
  unparseable input and `:257-260` returns `noOp()` on non-zero hook exit. Hooks run on
  every tool call, so a halt-on-unknown adapter would break the host on each call. The
  plan must state the split explicitly: fail-closed in the control plane, fail-open in
  the hook plane, explicit-unbound in the data plane.

### 3H. ARCHITECTURE.md disposition (DOWNGRADED — user correction 2026-07-25)
User clarifies ARCHITECTURE.md documents the *failed* architecture under rebuild; it
is not a spec the plan must honor. So this is not "the plan violates the architecture"
— it is only a cheap housekeeping item: a 67KB doc whose opening line calls itself
"the operational source of truth" sits at repo root and will be re-read as current by
the next session/agent. Action is a superseded banner, not a rewrite.
The codex report's use of `ARCHITECTURE.md:13` still stands, since that indictment is
about the claim/code gap, not about the doc being authoritative.

NOTE: finding 3G's fail-open point must be re-anchored on code, not on this doc —
see revision below.

### 3I. Phase 0 "freeze" is advisory, and a gate has no owning action
- `ctx_upgrade` remains advertised to every currently-connected client (Codex, Cursor,
  Antigravity). A policy freeze does not stop a model from calling it. Phase 0 needs a
  mechanical block (drop the tool from the advertised list, or take non-Claude MCP
  registrations down). Same criticism the plan levels at advisory routing elsewhere.
- `node/package.json` postinstall re-applies patches on any `npm install`/`npm ci`.
- Release gate "Production client storage contains no synthetic test fixtures" has no
  corresponding phase action that cleans it (codex report: 50 of 51 Codex session rows
  synthetic; one test PID reused across ten project databases).

## 4. Overall
Diagnosis is sound and unusually well-evidenced; target architecture is right.
Main weaknesses are sequencing (no cheap-fix tier before a hard fork), one missed
mechanism that is both the best causal hypothesis and the cheapest test (3A), and
several gates without owning actions.
