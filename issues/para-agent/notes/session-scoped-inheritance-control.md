# Session-scoped inheritance control for participants

- **Written:** 2026-08-19
- **Status:** proposal. Landing any of it amends
  [CLIENT-INTEGRATION-CONTRACT](../../../mcp/para-agent/contract/CLIENT-INTEGRATION-CONTRACT.md)
  §Environment and secret boundary and the adapter schema — so it is a note, not canon.
- **Precedes:** [client-asset-provenance](../notes/client-asset-provenance.md) (P21),
  [client-discovery-inventory-20260819](../reports/client-discovery-inventory-20260819.md)

## Goal

Every participant launched within the scope of the para-agent MCP has its behavior and context
injections determined by the session, not by whatever its vendor happens to discover on the host.
Controlled at session level, through environment and session configuration.

## Posture: label, don't gate

**Isolation is the target, not the entry requirement.** A client whose configuration surface is not
yet characterized still launches, still mediates, and still gets used during development — it is
simply *labeled* with what was and was not controlled. Refusing to launch what isn't yet understood
blocks exactly the runs that would produce the understanding, and the edges worth fixing only
surface under use.

This is P6's pattern, not P12's. P6 demoted adapter `verified_versions` from a launch gate to an
evidence label precisely because a pin that blocks launch buys nothing that an honest label does not
buy. Inheritance controls take the same demotion: they describe what a launch achieved, they do not
decide whether it may happen.

The invariant that stays hard is the **claim**, never the launch:

- A receipt never reports isolation it did not achieve.
- A label is never upgraded by omission — an uncharacterized client reads `unknown`, not `none`.
- Gating is available but **opt-in per session** (`require_inheritance: witnessed | declared`), off
  by default. Reach for it when a specific session needs the guarantee; never as the global posture.

Under this posture the labels double as a **discovery instrument**: every launch of an
uncharacterized client emits a receipt naming what was uncontrolled, which is how the fleet gets
characterized in the first place.

## What already holds

The environment axis is already deny-by-default in the frozen contract:

> Managed compilation starts from an empty map plus explicitly declared platform/client
> inheritance. The private plan contains the complete child environment. Backends pass it verbatim
> and never merge `process.env`.

So the *mechanism* for strict environment control exists and is contractual. Two things are
missing, and neither is plumbing.

**Missing 1 — the intent is unnamed and unportable.** `src/adapters/claude.json` already launches
with `--safe-mode`, which disables CLAUDE.md, skills, plugins, hooks, MCP servers, custom commands,
agents, output styles, and workflows. That is exactly the isolation being asked for — but it lives
as an opaque string inside `transport.command`, adjacent to `--output-format stream-json` and
indistinguishable from it. Nothing in the system can answer *"what does this participant inherit?"*
without a human reading each adapter's argv array and knowing each vendor's flag semantics. Add a
fifth client and the question has to be re-answered from scratch.

**Missing 2 — no witness.** Nothing observes whether the isolation took. This is the same gap that
holds P10 open for Grok and P12 closed for AGY, arriving from a different direction.

## The three levers, per client, as of 2026-08-19

Evidence: `--help` surfaces of the installed builds and the fleet census.

| | Config-home redirect | Inheritance kill-switch | Positive injection | Self-report |
|---|---|---|---|---|
| **Claude 2.1.233** | `--settings <file\|json>`; `CLAUDE_HOME` is set in the user's own settings but **unverified** as a redirect | `--safe-mode` (all customizations off), `--bare` (hooks, LSP, plugin sync, auto-memory, keychain, CLAUDE.md auto-discovery off), `--setting-sources user,project,local` | `--mcp-config` + `--strict-mcp-config`, `--add-dir`, `--agents`, `--plugin-dir`, `--system-prompt[-file]`, `--append-system-prompt` | none found |
| **Grok 1.0.4** | `GROK_HOME` | `[compat.<vendor>] <surface> = false` × 3 vendors × 6 surfaces, or the `GROK_*_ENABLED` env equivalents; folder trust is default-deny for repo-local MCP/LSP/hooks | **none** — no `--mcp-config` equivalent | `grok inspect --json`, with per-asset source, vendor, and enable state |
| **Codex 0.147.0** | `CODEX_HOME` | `--profile <name>` layers `$CODEX_HOME/<name>.config.toml`; `--strict-config` | `-c mcp_servers.<name>...=` overrides | `codex doctor` |
| **AGY 1.1.13** | unknown | unknown | unknown | unknown |

Read the asymmetries, because they are the whole design problem:

- **Claude can be told what to load; Grok can only be told what not to scan.** One expresses
  allowlist semantics, the other denylist. The same session intent therefore compiles to a
  materially different guarantee per client, and pretending otherwise is how an unproven claim gets
  made.
- **Only Grok can report its own resolution.** Claude exposes no equivalent of `inspect --json`.
  Where no self-report exists, isolation is *declared and unwitnessed* — and must be recorded that
  way rather than asserted.
- **AGY is unknown on all four counts**, consistent with P12 holding it fail-closed.

## Proposed shape

This does **not** need a sixth axis. It decomposes onto the existing five (P5), with one new
declaration object and one new readiness dimension.

### 1. Session profile declares intent — client-agnostic

```
inheritance:
  mode: "none" | "declared" | "ambient"
  inject:
    instructions: [ ...explicit sources... ]
    mcp_servers:  [ ...explicit definitions... ]
    skills:       [ ... ]
    hooks:        [ ... ]
```

`none` is the default and means *the participant discovers nothing it was not handed*. `ambient` is
the escape hatch and must be explicit, never reachable by omission. Nothing here names a vendor.

### 2. Adapter declares the mechanism — per application and version

Alongside the existing `capabilities` block, which already carries this exact discipline:

```
inheritance_controls:
  config_home_env: "GROK_HOME"            # or null
  deny_all: ["--safe-mode"]               # argv realizing mode: none
  deny_partial: { mcps: {...}, hooks: {...} }
  inject_mcp: "--mcp-config" | null       # null ⇒ allowlist semantics unavailable
  self_report: { command: [...], parser: "..." } | null
```

Version-scoped and evidence-backed, same as `verified_versions` under P6: a flag set verified for
`2.1.226` is not evidence for `2.1.233`. Where a control is `null`, the compiler applies what it
has, launches anyway, and **downgrades the label** — it never silently approximates the requested
mode, and it never refuses on that basis alone. An adapter with no `inheritance_controls` block at
all is legal; it compiles to `unknown` and launches.

### 3. Host binding supplies the values

Session-owned sterile config home, per participant. The compiled environment already starts empty,
so this is a value to declare, not a new mechanism.

### 4. Readiness witnesses it

New dimension: `inheritance`, reported as a label and never as a veto:

| Label | Meaning |
|---|---|
| `witnessed` | self-report enumerated the resolved sources and they match the declaration |
| `declared` | controls applied, no self-report available to confirm |
| `partial` | some requested controls have no mechanism on this client; names which |
| `uncontrolled` | launched with vendor defaults, deliberately |
| `unknown` | surface not characterized yet — the honest default for a new client |

Grok reaches `witnessed` today via `inspect --json`. Claude reaches `declared` and should say so
rather than inherit the benefit of the doubt. AGY reads `unknown` and **still runs** — that label is
what makes its edges visible, and running it is how they get found.

### 5. Receipt records declared vs witnessed

Which is the durable answer to *"what was this participant actually running with?"* — the thing
that is archaeological today.

## The property that makes this worth doing twice over

A config-home redirect is simultaneously an **input-scope control and an output-containment
control**. `GROK_HOME` / `CODEX_HOME` govern what the participant reads *and* where it writes its
sessions, logs, and state.

That second half is the general hygiene problem in miniature: this repository's `.codex/` directory
holds `agy-native-stream-capture/`, `chat-export/`, and `doc-dive/` output — artifacts of other
clients and of para-agent itself, deposited under a vendor's name because that vendor's defaults put
them there and nothing said otherwise. A session-owned home per participant makes vendor-named
directories in the repository unnecessary, and makes an artifact's owner readable from its path.

## Sequencing and the blocker

**P14 gates the guarantee, not the design.** Managed mux is unavailable with
`CLIENT_ENV_ISOLATION_UNPROVEN` until isolated control-environment and pane inheritance are
evidenced. Session-level environment control is only as strong as the launch path that carries it,
and a tmux pane inheriting the server's environment defeats it silently. So:

1. Land declaration + compilation + receipt on the **direct-spawn** path, where the contract's
   verbatim-environment rule already holds.
2. Let mux run, labeled. Pane environment inheritance is unwitnessed, so a mux-launched participant
   reads `unknown` on the inheritance dimension until a pane probe says otherwise — that is a label,
   and it is what makes the pane-inheritance edge observable instead of theoretical.
3. Add the `inheritance` readiness dimension with Grok as its first `witnessed` client — which is
   the same runtime witness P10 is waiting on. **One probe closes both.**

That last point is the cheapest thing on this list: the isolation witness owed to P10 is the
prototype for the readiness dimension proposed here.

## Three existing rulings that gate where they could label

Not proposals to retire the concerns — proposals to convert each from a stop into a label, so
development proceeds and the concern stays visible. Each is a separate ruling and none is made here.

| Ruling | Currently | Under this posture |
|---|---|---|
| **P10** — Grok managed mediation no-go until tool isolation is evidenced | Blocks the pilot | Self-blocking: the pilot is what produces the evidence. The 2026-08-19 controls are now documented and applied, so the pilot could run at `declared` and be *promoted* to `witnessed` by the same run |
| **P12** — AGY fail-closed until a fresh native stream capture | Blocks AGY entirely | AGY's real risk is *stream misinterpretation*, which is a correctness concern and a genuinely different thing from inheritance. Worth separating the two so an uncharacterized config surface does not inherit a stream-correctness veto |
| **P14** — managed mux unavailable with `CLIENT_ENV_ISOLATION_UNPROVEN` | Blocks the mux path | Run labeled `unknown`, with the pane-inheritance probe as the promotion path |

P12 is the one to leave alone longest: a client whose stream is misread produces *wrong transcript
content*, which is worse than an over-permissive launch because it corrupts the record rather than
the blast radius.

## Open questions

- Does Claude Code honor `CLAUDE_HOME` or an equivalent as a config-home redirect? Set in the
  user's settings today, unverified as a mechanism.
- `--setting-sources` accepts `user,project,local` — is an empty value legal, and what does it mean?
  (Same shape as the unresolved `--tools ""` empty-allowlist question for Grok in W0.)
- Is there any Claude self-report of resolved MCP/skill/hook sources that does not start servers?
  `grok mcp doctor` is disqualified for exactly that reason.
- AGY: all four levers unknown. Characterize it by **running** it labeled `unknown` and reading what
  the receipts expose, rather than by holding it out of use until a probe that nobody is scheduled to
  write gets written.
