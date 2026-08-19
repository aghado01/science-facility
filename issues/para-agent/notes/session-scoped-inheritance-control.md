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
`2.1.226` is not evidence for `2.1.233`. Where a control is `null`, the compiler **cannot** claim
that mode and must fail closed rather than approximate it.

### 3. Host binding supplies the values

Session-owned sterile config home, per participant. The compiled environment already starts empty,
so this is a value to declare, not a new mechanism.

### 4. Readiness witnesses it

New dimension: `inheritance`, with three states — `witnessed` (self-report enumerated the resolved
sources and they match the declaration), `declared` (controls applied, no self-report available),
`unproven` (fail closed). Grok can reach `witnessed` today via `inspect --json`. Claude cannot, and
should say so rather than inherit the benefit of the doubt.

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
2. Keep mux fail-closed until pane environment inheritance is witnessed, not assumed.
3. Add the `inheritance` readiness dimension with Grok as its first `witnessed` client — which is
   the same runtime witness P10 is waiting on. **One probe closes both.**

That last point is the cheapest thing on this list: the isolation witness owed to P10 is the
prototype for the readiness dimension proposed here.

## Open questions

- Does Claude Code honor `CLAUDE_HOME` or an equivalent as a config-home redirect? Set in the
  user's settings today, unverified as a mechanism.
- `--setting-sources` accepts `user,project,local` — is an empty value legal, and what does it mean?
  (Same shape as the unresolved `--tools ""` empty-allowlist question for Grok in W0.)
- Is there any Claude self-report of resolved MCP/skill/hook sources that does not start servers?
  `grok mcp doctor` is disqualified for exactly that reason.
- AGY: all four levers unknown. Fail closed until probed.
