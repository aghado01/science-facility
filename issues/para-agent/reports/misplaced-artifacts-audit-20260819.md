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

## F8 — one short name, two referents, inside para-agent's own canon

`agy` names two different things, and the canon uses both without qualification:

| | The **role** | The **application** |
|---|---|---|
| What | standing adjutant pane, psmux session `agent-agy` | Google Antigravity CLI |
| Driven by | headless `claude.exe -p` | `agy.exe` 1.1.13 |
| Evidence | four engagements 2026-08-10→13, $2.42–$7.15 each, high hit rate — [agy-usage-report](../specimens/agy-usage-report-20260813_100903.md), [fable-agy-TexDig-triage](../specimens/fable-agy-TexDig-triage-20260812.md) | one capture attempt, 0 bytes of stdout, OAuth timeout — [agy-native-stream-capture-20260814](../specimens/agy-native-stream-capture-20260814/README.md) |
| Status | worked | never reached a stream |

Confirmation that the role is claude-backed, from the usage report's own §2 turn pattern:
`claude.exe -p (Get-Content <promptfile> -Raw) --allowedTools Read Grep Glob --output-format json`.
L1 adds that gemini is not installed and that `claude` 2.1.226 resolves on the pane PATH. Neither
`agy.exe` nor Antigravity appears anywhere in that document.

The two live side by side in `specimens/` under names that do not distinguish them, and P12 ruled on
the application while the field evidence describes the role. Disambiguated in P12 and in the capture
README on 2026-08-19; the underlying names are unchanged and remain the owner's call.

Not a finding: `research/skills/claude-agy/` holds a vendor skill about Antigravity delegation, with
a byte-identical `SKILL.md` / `antigravity-agents.md` pair. `research/` is a corpus, not a load path
— nothing in the repository or in any client config references it, and the canonical shared-skill
location is `skills/`. Recorded only so the next reader does not re-flag it.

## F9 — rooting gaps against the standalone design

Stated intent (owner, 2026-08-19): everything para-agent owns is rooted under `mcp/para-agent` —
its own skills, its own vendored `nu` and mux, eventually other MCPs vendored in — so the package is
transplantable. `PARA_PKG_ROOT` (para-agent's own world) versus `PARA_WORKSPACE_ROOT` (the project it
operates on) is the split that expresses this, and both are already in `profiles.js`.

Most of it holds: `skills/` (`primary/`, `sub-agents/{para,self}`), `bin/{nu,mux}`, `profiles/`,
`personas/`, `brewery/`, `capture/`, `contract/`, `resources/`, `src/` are all inside the root.
Three things are not.

**9a — the test suite lives outside the package root.** `package.json` runs
`../tests/para-agent/run.ps1`; the suite and its fixtures are at `mcp/tests/para-agent/`. Worse for
transplantability, two adapters carry **repo-relative** evidence references:

```
src/adapters/claude.json:18  "reference": "mcp/tests/para-agent/fixtures/adapters/claude/2.1.226/stdout.reduced.jsonl"
src/adapters/codex.json:18   "reference": "mcp/tests/para-agent/fixtures/adapters/codex/0.147.0/stdout.jsonl"
```

Those paths resolve only from the repository root. Moved elsewhere, the package's own verification
evidence becomes unreachable from the adapters that cite it.

**9b — `mcp/para-agent/tests/` exists and is empty.** A stub inside the root while the real suite
sits outside it. Either the intended destination or a leftover; it currently states an ownership the
tree does not honor.

**9c — the vendored runtime is untracked, and so is its configuration.** `.gitignore:37` (`bin/`,
alongside `**/bin/**`) is aimed at build output and catches the vendored runtime as collateral:

```
$ git ls-files mcp/para-agent/bin        # (empty)
$ git check-ignore -v mcp/para-agent/bin/nu/nu.exe
.gitignore:37:bin/    mcp/para-agent/bin/nu/nu.exe
```

The binaries themselves should probably stay out — `bin/nu` is **176 MB**, `bin/mux` 6.7 MB. But the
ignore also swallows 98 KB of non-binary files, including **`bin/mux/mux.conf`**, which `.mcp.json`
names directly:

```json
"PARA_MUX_CONFIG_FILE": "./mcp/para-agent/bin/mux/mux.conf"
```

So a fresh clone gets a para-agent whose declared mux config path does not exist, and whose
`PARA_NU_BIN` / `PARA_MUX_BIN` point at absent executables, with nothing in the repository recording
what should be there. The thing that makes the package self-contained is the thing that does not
travel with it.

**9d — the resolvers fall back to ambient binaries, silently.** `bin/` holding untracked compiled
payload is deliberate; a clone rehydrates it. The gap is what happens when it has not been
rehydrated. Both resolvers in `src/mux.js` end the same way:

```js
resolveNuBin()  → ... → return "nu";               // mux.js:74
resolveBin()    → ... → return BIN_CANDIDATES[0];  // mux.js:57 — "tmux.exe" on win32
```

Bare names, resolved by the OS against `PATH`. So an unhydrated `bin/` does not fail — it silently
substitutes **the host's** nushell and mux for the vendored ones. The dedicated runtime was vendored
precisely to not depend on ambient tooling, and the last line of each resolver hands the ambient one
back without a word. That is the inheritance problem this audit catalogues, occurring inside
para-agent's own launch path.

The declared-path case has the mirror hole: `resolvePath()` returns `cwdResolved` even when nothing
exists there (`mux.js:31`), and neither resolver existence-checks an env-supplied path. `.mcp.json`
sets `PARA_NU_BIN=./mcp/para-agent/bin/nu/nu.exe`, so on an unhydrated clone that resolves to a
concrete path pointing at nothing, and the failure surfaces later as an opaque spawn error rather
than as *"rehydrate `bin/`"*.

Neither is an argument for refusing to launch — per the label-don't-gate posture, the fix is that the
resolved runtime and **where it came from** (vendored / ambient / declared-missing) are recorded,
and that the missing-vendored case names its remedy.

**The layout the findings point at.** Owner is honing this in `codex-scientiae`, cited as ideas
rather than a template to copy. The load-bearing idea is a three-way split by *how a directory is
obtained*, expressed in the ignore file:

| Role | codex-scientiae | Ignore treatment | para-agent's equivalent |
|---|---|---|---|
| Recipes — how to obtain things | `brewery/` | absent from `.gitignore` ⇒ **tracked** | `brewery/` (exists, empty) |
| Rehydrated payload | `packages/` | `packages/` ⇒ ignored | `bin/` — already correct |
| Regenerable output | `artifacts/` | `artifacts/**` + **`!artifacts/README.md`** | `.para-agent/` at the workspace root |

Two things follow for para-agent specifically. First, `bin/` is already playing the `packages/` role
correctly — untracked payload is the right call and no change is wanted there. What is missing is
the `brewery/` half: nothing yet records how `bin/` gets filled. Second, the `!README.md` negation is
the answer to *"a directory whose contents are ignored should still declare what it is"* — which is
exactly the gap in F9c, and it costs one file.

Worth noting that para-agent's ignore policy is currently not para-agent's: `bin/` is ignored by
`.gitignore:37` at the **repository** root, a repo-wide rule aimed at build output. Under the
standalone design the package should carry its own `.gitignore`, both so the policy roots with the
thing it governs and so it survives transplanting.

**Note for the planned vendoring.** `mcp/nushell-mcp` left para-agent because the concept is useful
outside it, and is to come back as the front-end shell experience. Its layout authority is
`config.nu`, and the reference corpus is deliberately not duplicated into the Claude-side adapter.
Vendoring it in should keep that shape — one corpus, referenced by the vendored copy — or the
duplication becomes another provenance problem of exactly the kind this audit catalogues.

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
| R8 | Move `bin/mux/mux.conf` out of `bin/` to a tracked config location and repoint `PARA_MUX_CONFIG_FILE`. `bin/` then holds **only** rehydratable payload — one directory, one meaning | F9c. Preferred over un-ignoring files inside `bin/`, which leaves a mixed-ownership directory |
| R9 | Put the rehydration knowledge in **`brewery/`** — pins, checksums, fetcher scripts, everything a cold setup needs for `bin/nu` and `bin/mux`. The directory already exists and is empty; nothing ignores it, so it is tracked by default | F9c. Supersedes the earlier "manifest at package root" phrasing. See the layout note below |
| R12 | Give `bin/` a tracked `README.md` via ignore negation, stating what belongs there and pointing at its brewery recipe — the `!artifacts/README.md` pattern. A directory whose contents are ignored can still declare itself | F9c/F9d. This is the repo-level half of "para-agent knows the binary lives there"; R11 is the runtime half |
| R13 | Give `mcp/para-agent/` its **own** `.gitignore`. Today `bin/` is governed by `.gitignore:37` at the repository root — para-agent's ignore policy lives outside the package it governs, which is the same rooting violation as F9a | F9. Also makes the package's ignore rules travel with it |
| R11 | Record resolved-runtime provenance (vendored / ambient / declared-missing) and give the unhydrated case a named error stating the remedy. Do **not** refuse to launch on ambient fallback — label it | F9d. Same posture as the inheritance dimension; the two want the same receipt field |
| R10 | Move the suite to `mcp/para-agent/tests/` (the empty stub) and make adapter evidence references package-relative | F9a, F9b. Larger change; touches `package.json`, the runner, and two adapter files. Do it when the migration track is already disturbing these files |

**The general rule these argue for:** an artifact's directory should name *what produced it or what
it is about*, never *which client happened to be running*. A vendor dot-directory holds that vendor's
own configuration and nothing else.

## Limits

Repository working tree and personal-scope client configs on this machine only. Other repositories
under `D:\aghado01` were not swept, and the same `.codex/chat-export/` pattern is known to exist in
`codex-scientiae` from a prior transcript reference.
