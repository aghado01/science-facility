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

## F1 — para-agent's own state root is launcher-determined, not server-owned

**Live code.** [`src/index.js:48`](../../../mcp/para-agent/src/index.js:48):

```js
const defaultJournalRoot = path.join(process.cwd(), ".para-agent", "journals");
```

and three call sites passing `workspaceRoot: process.cwd()` — [index.js:58](../../../mcp/para-agent/src/index.js:58),
[index.js:65](../../../mcp/para-agent/src/index.js:65), [index.js:265](../../../mcp/para-agent/src/index.js:265).
The comment above it says the quiet part: *"Workspace-contextual if `PARA_JOURNAL_ROOT` is unset."*

The frozen contract says the opposite:

> A **server-owned workspace root** and handle-derived ledger session select the transcript store.
> Request `cwd` never changes that route.

Request `cwd` indeed doesn't change it — **process** cwd does, and process cwd is whatever directory
the launching client happened to start the server from. Two clients launching para-agent from two
directories get two transcript stores, silently, with no error and no receipt of which one was used.

This is the same defect as everything in F3, expressed in code: **location determined by the
launcher rather than by the owner.** It is the generator of the problem, not an instance of it.

The fossil is in the tree: `mcp/para-agent/.para-agent/` exists and is **empty** — a launch from that
directory that created the tree and wrote nothing. Real state lives at the repo root
(`.para-agent/journals/streams/agent-cli-test/`, `.para-agent/transcripts/`).

Note the asymmetry: journals have an env override (`PARA_JOURNAL_ROOT`), transcripts have none —
`workspaceRoot` is hard-wired to `process.cwd()` at every call site. That is the smaller half of the
fix and it is directly on the path the [inheritance-control note](../notes/session-scoped-inheritance-control.md)
proposes.

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
| R1 | Give para-agent a server-owned state root — resolve from the package/server location or an explicit `PARA_WORKSPACE_ROOT`, not `process.cwd()`; give transcripts the same override journals already have | Code change, closes F1 at the source. Belongs with the inheritance-control work |
| R2 | Move `agy-native-stream-capture/` and `agy-native-stream-probe.mjs` into `issues/para-agent/` as tracked evidence, and correct P12 to say what actually happened | Closes F2. The ruling needs amending either way |
| R3 | Delete the empty `mcp/para-agent/.para-agent/` and `.codex/chat-export/` | Empty fossils |
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
