# Misplaced artifacts and cross-wired configuration — audit 2026-08-19

- **Scope:** this repository's working tree plus the personal-scope client configs on this machine.
  Two questions: *which artifacts sit under an owner that did not produce them*, and *where is one
  client pointed at another's configuration or skills*.
- **Method:** filesystem sweep, tracked-file greps, and reads of the implicated sources. Nothing was
  moved, deleted, or rewritten.
- **Companion:** [client-discovery-inventory-20260819](client-discovery-inventory-20260819.md) covers
  the config surfaces themselves; this covers the mess they left behind.

Findings are ordered by consequence, not by how they were found.

---

## F1 — the workspace root was intended but never named — *resolved 2026-08-19*

> **Corrected.** This finding was first written as "state root is launcher-determined, not
> server-owned", reading `process.cwd()` as drift against the contract. That was wrong on intent.
> Owner's account: cwd-derivation is deliberate — a supervisor working in project X launches
> para-agent there so both land in the same workspace, and `<workspace>/.para-agent/` is a planned
> convention for repo-scoped working files that can be written and resumed per project. The empty
> `mcp/para-agent/.para-agent/` is a placeholder for that convention, not a fossil. Retained here
> with the real gap, which is narrower.

`src/index.js` derived the workspace root from `process.cwd()` **inline at four separate points** —
the journal root plus three call sites — with the value never named, never overridable, and never
reportable. Workspace-scoping was the design; the workspace itself was implicit.

`profiles.js` already had the vocabulary: it passes both `PARA_PKG_ROOT` (where para-agent lives)
and `PARA_WORKSPACE_ROOT` (the workspace) into the nu profile environment. The distinction was
codified in one module and absent in the one that resolves it.

Consequences of leaving it implicit: journals had an override (`PARA_JOURNAL_ROOT`) and transcripts
had none; a launch whose cwd was not the workspace had no way to say so; and nothing could report
which workspace a session actually bound to.

**Fixed** in [`index.js`](../../../mcp/para-agent/src/index.js:57): `WORKSPACE_ROOT` resolves once at
startup, `PARA_WORKSPACE_ROOT` overrides, `process.cwd()` remains the documented default, and all
four sites read the single value. Behavior under a conventional launch is unchanged. Bounded gate
after the change: **21 suites / 218 discovered / 218 passed / 0 failed, skipped, or cancelled.**

Still open, and now a wording question rather than a code one: the frozen contract says *"a
**server-owned** workspace root … selects the transcript store"*, which does not describe
workspace-scoped resolution. The contract text, not the code, is what needs the ruling.

---

## F2 — the AGY capture that P12 rests on failed at OAuth, and nobody read it

`.codex/agy-native-stream-capture/` holds a real capture attempt, `metadata.json`:

```
"application": "agy",  "version": "1.1.13",
"launched_at": "2026-08-14T21:21:19Z",  "completed_at": "2026-08-14T21:22:20Z",
"process": { "code": 1 },  "stdout": { "bytes": 0 },  "stderr": { "bytes": 939 }
```

`stderr.raw` is a Google OAuth device-login prompt, then:

```
Waiting for authentication (timeout 60s)...
Error: authentication timed out.
```

**AGY did not fail a stream test. AGY never reached one.** Zero bytes of stdout — the process died at
interactive browser authentication, 60 seconds in, before emitting a single native event.

P12 currently reads *"AGY remains fail-closed until its profile is independently evidenced by a fresh
native stream capture."* That ruling is standing on a capture that never captured, and the actual
edge is a different one entirely: **para-agent's non-interactive spawn cannot complete an
interactive OAuth flow.** That is an authentication-carrier problem, not a stream-correctness
problem, and it is the kind of edge that only surfaces by running the thing.

No planning document cites this capture. It is referenced nowhere in the repo except the reports
written today — because it lives in a gitignored directory (F5), so it was invisible to every later
reader including the one who wrote P12.

`.codex/agy-native-stream-probe.mjs` is the probe **script** that produced it — implementation, not
output, sitting in the same ignored vendor directory.

---

## F3 — `.codex/` holds four classes of artifact, none of them Codex's

| Path | What it actually is | Owner |
|---|---|---|
| `agy-native-stream-capture/` | AGY 1.1.13 launch evidence (F2) | para-agent |
| `agy-native-stream-probe.mjs` | the probe script that produced it | para-agent |
| `doc-dive/20260810_193419/` | mdnav corpus index + reads | doc-dive tooling |
| `doc-dive-vscodepilot/20260810_200456/` | mdnav output from a **VS Code Copilot** session | doc-dive tooling |
| `chat-export/` | empty directory | chat-export tooling |

The Copilot one is the clearest statement of the problem: artifacts from one vendor's agent, filed
under a second vendor's name, by a third party's tool.

`.claude/doc-dive/` (two runs, 2026-08-06) is the same pattern under Claude's name. Neither directory
contains any actual Claude or Codex configuration.

---

## F4 — three competing conventions for one tool's output

`skills/doc-dive/mdnav/mdnav.mjs:75` declares `const ARTIFACT_DIR = '.doc-dive'`, resolved
**local to the corpus** (`<corpus>/.doc-dive/<UTC timestamp>/`), with `MDNAV_WORK_DIR` as the
override (`mdnav.mjs:90`).

So the tool's own default is corpus-local and correct. Observed on disk:

| Location | Convention |
|---|---|
| `issues/reposnapshot/discussions/.doc-dive/20260817_025336/` | tool default — correct |
| `.claude/doc-dive/` | caller overrode to the client's dir |
| `.codex/doc-dive/`, `.codex/doc-dive-vscodepilot/` | caller overrode to a *different* client's dir |

The vendor-directory copies were not produced by the tool's defaults. Each was an agent deciding at
runtime that its own client's dot-directory owned the output — exactly the behavior described. Note
also the naming drift: `.doc-dive` (dotted, corpus-local) versus `doc-dive` (undotted, inside a
vendor dir).

---

## F5 — every vendor dot-directory is gitignored, so anything filed there leaves no trace

`.gitignore` ignores `.claude`, `.codex`, `.grok`, `.gemini`, `.copilot`, `.antigravity`,
`**/.doc-dive/**`, and `**/.para-agent/**`.

Correct for client-owned config and scratch. But it means **any evidence an agent files into a vendor
directory is invisible to the repository** — which is the mechanism by which F2 happened. The AGY
capture was produced, ignored, and forgotten within the same day it was needed.

---

## F6 — a global instruction points at a path that does not exist

`~/.claude/CLAUDE.md` states the doc-dive mdnav tools are found under
`D:\aghado01\science-facility\mcp\mdnav`.

`mcp/` contains `mdnav_v2`, `nushell-mcp`, `para-agent`, `pwsh_exec`, `tests`. There is no
`mcp/mdnav`. The only mdnav on disk is `skills/doc-dive/mdnav`.

Two references in the same instruction file, one stale. Left untouched — it is the user's global
instruction file and not mine to edit.

---

## F7 — repo tooling declared in personal-scope client configs

`pwsh_exec` is a tool that lives in this repository (`mcp/pwsh_exec/`), and its `.mcp.json`
declaration now uses repo-relative paths. It is *also* declared, with absolute
`D:/aghado01/science-facility/...` paths, in:

- `~/.claude.json` → `mcpServers`
- `~/.cursor/mcp.json` → `mcpServers` — **and no Cursor CLI is installed on this machine**

Those two copies drift silently from the repo's own declaration and outrank it in any client that
merges personal scope above project scope (demonstrated for Grok in the inventory). The Cursor copy
is pure residue: a config for an agent that isn't installed, still live as a discovery target for any
client with cursor compatibility enabled.

---

## Proposed remediation

Nothing below has been executed. Ordered by value.

| # | Action | Notes |
|---|---|---|
| ~~R1~~ | ~~Name and resolve the workspace root explicitly~~ | **Done 2026-08-19.** `WORKSPACE_ROOT` + `PARA_WORKSPACE_ROOT`; 218/218 green |
| ~~R2~~ | ~~Rescue the AGY capture; correct P12~~ | **Done 2026-08-19.** Moved to `specimens/agy-native-stream-capture-20260814/` with a README stating what it does and does not prove; P12 amended |
| R3 | Delete `.codex/chat-export/` (empty). **Keep** `mcp/para-agent/.para-agent/` — it is a placeholder for the repo-scoped convention, not a fossil | Corrected from the first draft |
| R4 | Move or discard `.claude/doc-dive/` and `.codex/doc-dive*/` | Ephemeral index output from August 6 and 10; likely just discard |
| R5 | Drop `pwsh_exec` from `~/.cursor/mcp.json`, or delete `~/.cursor/mcp.json` outright | No Cursor CLI installed. Personal-scope file — owner's call |
| R6 | Decide whether `pwsh_exec` belongs in `~/.claude.json` at all now that `.mcp.json` declares it repo-relative | Removing the personal copy makes the repo the single declaration |
| R7 | Fix the `mcp/mdnav` path in `~/.claude/CLAUDE.md` | Owner's file |

**The general rule these argue for:** an artifact's directory should name *what produced it or what
it is about*, never *which client happened to be running*. A vendor dot-directory holds that vendor's
own configuration and nothing else.

## Limits

Repository working tree and personal-scope client configs on this machine only. Other repositories
under `D:\aghado01` were not swept, and the same `.codex/chat-export/` pattern is known to exist in
`codex-scientiae` from a prior transcript reference.
