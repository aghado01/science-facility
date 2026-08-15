# Context-leak postmortem — Claude Code setup

Date: 2026-07-25. Evidence: `~/.claude/projects/**/*.jsonl` usage records (harness-written, independent of context-mode), 65 sessions in `D--aghado01` + 11 in `codex-scientiae`, spanning Claude Code v2.1.181 → v2.1.219.

Method: per assistant request, `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`, deduped by `requestId`. "Floor" = first request of a session = system prompt + tool schemas + skills + agents + CLAUDE.md + MEMORY.md, before any conversation.

Reproduce with `measure-context-floor.ps1` in this directory.

---

## Headline numbers

| item | measured | yours to control |
|---|---|---|
| Session floor, `D:\aghado01`, v2.1.219, post-unwire | **44,991 tok** | partly |
| Session floor, `D:\aghado01\codex-scientiae`, same version | **56,336 tok** | **yes — 11.3K delta** |
| Floor growth v2.1.181 → v2.1.219 | 35,650 → 47,829 (**+34%**) | no |
| context-mode's own resident cost | **~2,840 tok** (47,829 vs 44,991, same version) | recovered |
| Median *total* context per request, mid-size sessions | **120K–320K** | yes — session hygiene |

---

## Finding 1 — project-scoped MCP servers are the most expensive thing you control

Same Claude Code version, same day, two project roots:

```
D--aghado01                  n=31  floor 44,991 – 47,829
D--aghado01-codex-scientiae  n=11  floor 56,336 – 58,355
```

`D:\aghado01` has no `CLAUDE.md` and no `.mcp.json`. `codex-scientiae` has a 1,528 B CLAUDE.md (~382 tok) and `.mcp.json` declaring **three servers** (`codex-membrane`, `codex-arxiv`, `codex-scholar`).

382 tok of CLAUDE.md cannot explain an 11,300 tok delta. The remainder is **eagerly-loaded MCP tool schemas: ~3,600 tok per server**, resident on every request whether or not the server is used.

This corrects a claim made in the original investigation ("fewer MCP servers per workspace isn't an available lever"). That was true for *app-provided* surfaces (`ccd_*`, `visualize`, `Claude_Browser`, `claude-in-chrome`) which you don't register. It is false for **project-scoped `.mcp.json`** servers, which are entirely yours.

Note the asymmetry worth exploiting: some MCP surfaces arrive **deferred** (name-only, ~20 tok each, schemas fetched on demand via `ToolSearch`) and some arrive **eager** (full schema resident). The codex-* servers are eager. Deferral is a client decision you don't control — but *registration scope* is.

**Action:** move `codex-*` servers out of `.mcp.json` and register them only when doing scholarly work, or split the project so arxiv/scholar/membrane load only in the subtree that needs them. Saves ~11K/session in that root.

## Finding 2 — the skill listing is 2,574 tokens and you no longer own any of it

Per-session attachment breakdown, measured:

| attachment | bytes | ~tokens |
|---|---|---|
| `skill_listing` | 10,297 | **2,574** |
| `deferred_tools_delta` | 3,697 | 924 |
| `agent_listing_delta` | 2,538 | 634 |
| `mcp_instructions_delta` | 1,097 | 274 |
| **total** | 17,629 | **~4,406** |

Your seven global skills (~644 tok) are already gone — `~/.claude/skills/` is empty. That cleanup landed and was correct.

What remains is app-bundled: `anthropic-skills:*`, `dataviz`, `artifact-*`, `claude-api`, `simplify`, `loop`, `run`, `init`, `review`, `security-review`, etc. `installed_plugins.json` is `{"version":2,"plugins":{}}` and the `claude-plugins-official` marketplace has **nothing installed** — the 28 SKILL.md files under `~/.claude/plugins/marketplaces/` are catalogue entries, not resident cost. So "plugin bloat" is, on measurement, **not a real leak in your setup**: you have zero plugins installed.

The 2,574 tok is a harness floor with no disk-side lever. Don't spend effort here.

## Finding 3 — `enableWorkflows: true` contradicts your own policy and is not free

`~/.claude/settings.json` sets `enableWorkflows: true` and `skipWorkflowUsageWarning: true`. That makes the `Workflow` tool schema resident on every request (it is one of the largest single tool descriptions in the prompt, order ~3–3.5K tok), and keeps the `Agent` tool plus `agent_listing_delta` (634 tok measured) loaded.

Your global CLAUDE.md says **"NO SUB-AGENT DISPATCH IS ALLOWED"**. So you are paying a standing schema cost for a capability you have forbidden by policy.

Caveat, stated plainly: the ~3–3.5K figure is an *estimate* from the schema's visible length, not a measurement — unlike every other number here. It is also in tension with UltraCode, which requires workflows. Toggle it and re-run the measurement script to get the exact delta.

**Action:** decide whether you want workflows at all. If yes, keep it. If no, drop both keys and measure.

## Finding 4 — the floor grew 34%, and that part is not yours

```
v2.1.181   35,650      v2.1.215   44,993
v2.1.187   40,388      v2.1.217   47,155
v2.1.205   44,917      v2.1.219   47,829 (44,991 post-unwire)
```

Floor tracks Claude Code version almost perfectly; the within-version spread is your config. **+12,179 tok of the increase since 06-26 is harness growth**, not configuration drift. Chasing it is wasted effort — but it does mean the *same* setup costs a third more per session than it did in June, which plausibly explains a perceived regression that had nothing to do with the nexus.

## Finding 5 — transcript duplication costs disk, not tokens

Sessions `87e78cad`, `580b2a8c`, `ed1b9fb5` each hold 43 requests. **All 43 `requestId`s are identical across all three files** — one conversation recorded three times, billed once.

Cost is storage and export ambiguity, not spend: `D--aghado01` 82.8 MB / 65 files, `D--aghado01-codex-scientiae` 189.8 MB / 107 files, ~336 MB total across roots.

This also reproduces **without context-mode**: at 10:22 on 07-25, eight hours after the hooks were stripped from `settings.json` (02:02) and with no MCP registration, one prompt that was interrupted twice produced three session ids (`189d5cb8`, `5e4889e8`, `f161995e`), each with a full attachment set. Interrupt → re-key → new transcript is harness behaviour. Recorded here only so it is not re-attributed to the nexus later; not pursued further per your instruction.

## Finding 6 — RETRACTED. The right metric is per-turn context growth, and it does not settle the question

**First draft of this finding was wrong.** It measured median *output* tokens per request and concluded the regression "is not in the harness data." Output tokens are not what a result-interception layer compresses. Context-mode shrinks **tool results entering the conversation** — the per-turn context increment. Given Finding 7 (cache reads are 92% of volume, growing quadratically in conversation size), the increment is precisely the term that matters. Measuring output was measuring the wrong variable.

Corrected metric — median tokens *added to context per turn*, fleet-wide by day:

```
06-25  7,390    07-02  1,714    07-15  1,406    07-22  3,358
06-26  7,870    07-03  1,634    07-16  1,832    07-23  2,177
06-28  7,742    07-04  3,512    07-17  2,653    07-24  2,755
06-30  2,388    07-05  2,039    07-19  2,603    07-25  2,135
07-01  4,224    07-06  1,280    07-20  1,832
```

A large sustained drop is visible — ~7,700/turn in late June to ~1,300–1,800/turn in early-to-mid July, roughly the 4–6× improvement described. Best sessions fleet-wide run at **915–1,257 tok/turn**. Current sessions run ~2,100–2,300 with spikes far above.

**But the attribution is not established, and two pieces of evidence cut against the obvious reading:**

1. Every session in the improvement window records **zero `ctx_*` tool calls**, and context-mode's MCP server did not connect to `D--aghado01` until **07-21 19:50** — three weeks after the drop.
2. Attributing growth to the tool that produced it, across all `D--aghado01` sessions: `ctx_*` turns median **4,995**, raw-tool turns median **3,399**, text-only turns median **3,401**. In the recorded data, `ctx_*` turns were *more* expensive — though all 74 fall in the 07-22→07-25 broken window, where `ctx_execute` carried large inline JS payloads.

**The measurement limitation, stated plainly:** the savings mechanism you describe is the **hook layer** — `PostToolUse` intercepting and compressing results before they enter context. That is invisible to transcript analysis. A hook-truncated result and a naturally small result are byte-identical in the JSONL; there is no marker distinguishing them. So transcripts can show *that* per-turn growth changed but never *why*.

The day-level trend is also confounded by project and work mix: the low-growth window is dominated by very long `codex-scientiae` sessions (447–573 requests) where most turns are conversational, while late June is dominated by file-heavy `D--aghado01` work. Median per-turn growth falls when sessions get long regardless of tooling.

**Net:** this dataset can neither confirm nor refute the magnitude of context-mode's savings. What it does establish is the metric to instrument, and a measured target — **~1,000–1,300 tok/turn was achieved on this machine**; that is the benchmark any replacement should be held to. If the new system emits a per-turn `Δcontext` figure computed the way `measure-context-floor.ps1` does, the question becomes answerable rather than arguable, and it fails loud instead of reporting `100.0%` while idle.

### Worked example: this session

Per-turn context growth, `f161995e`, in order:

```
21961 20551 3952 1300 1485 1536 2924 4756 3017 4567 4086
 2038  1924 2293 6498 2927 1069  956  560  324 1458  334
```

Floor 45,003 → 140,903 across 24 turns. The first two entries are two `Read` calls on a 39K-token discussion file: **42,512 tokens of raw file content admitted to context**, never referenced again in full. A working result-interception layer would have admitted a summary and indexed the rest. That single pair is ~44% of everything this session added — a concrete instance of exactly the cost being described, and it is the strongest argument in this document for rebuilding the hook layer rather than only the tools.

## Finding 7 — where the tokens actually go

Fleet-wide, all project roots, all history (217 sessions / 17,647 requests):

```
output        39,572,582 tok
cache write  371,878,053 tok      9.4× output
cache read 4,886,077,381 tok    123.5× output
```

**Ninety-two percent of your token volume is cache reads** — the cost of re-sending accumulated conversation context on every turn. Output generation, the thing token-economy instructions target, is under 1%.

The floor is not the dominant cost either. Median *total* context per request, by session:

```
57cf060b  126 reqs  median 323,744/req   35.3M cache read
8698b01e  104 reqs  median 316,411/req   27.5M cache read
d111542e  105 reqs  median 316,411/req   27.9M cache read
```

Day totals: 07-23 alone was **211M cache-read + 24M cache-write tokens** across 1,133 requests in 18 sessions.

A 45K floor paid 65 times is ~2.9M tokens. A single long session carrying a 320K context across 126 turns is ~35M. **Session length dominates the floor by an order of magnitude.** The highest-leverage habit is ending sessions and starting fresh ones on topic change — not trimming preamble.

Cache reads grow *quadratically* in session length: turn N re-reads the whole prefix, so an N-turn session costs ~N²/2 × average-turn-size. Halving session length quarters the cache-read bill. Nothing in the preamble is close to that lever.

This is also why the original brief's framing — "conserve tokens by generating efficiently" — targets the smallest term. Terse output is worth <1% of spend; short sessions are worth most of the other 99%.

Confirmed non-issues: `MEMORY.md` 2,387 B (~597 tok) and global `CLAUDE.md` 2,174 B (~544 tok). Together ~1.1K, about 2.5% of the floor. The original investigation's verdict — "memory is not your problem" — holds.

---

## Ranked actions

| # | action | measured saving | effort |
|---|---|---|---|
| 1 | End sessions on topic change; don't carry 300K contexts | quadratic — dominates everything else | habit |
| 2 | Unregister `codex-*` MCP servers from `codex-scientiae/.mcp.json` unless in use | **~11.3K/session** in that root | 1 edit |
| 3 | Decide on `enableWorkflows` (conflicts with UltraCode) | est. 3–4K/session, unverified | 1 edit + measure |
| 4 | GC `~/.claude/projects/**` — 336 MB, much of it forked duplicates | 0 tokens, 336 MB disk | script |
| 5 | Leave `skill_listing`, `MEMORY.md`, `CLAUDE.md` alone | — | — |

Already banked: context-mode unwire (~2,840 tok/session + per-call PreToolUse nudges), global `ctx-*` skills removal (~644 tok/session).

## Corrections to the original investigation

1. **"Fewer MCP servers isn't an available lever"** — wrong for project-scoped servers. It is the biggest lever measured (Finding 1).
2. **"Boot latency → tool deferral → dead routing"** — already retracted in-session; deferral is blanket harness policy.
3. **"Plugin bloat"** — not present. Zero plugins installed; marketplace catalogue is inert (Finding 2).
4. **context-mode's resident cost** — measured at ~2,840 tok/session. That is only the *injection* cost. It says nothing about the hook layer's savings, which are unmeasurable from transcripts (Finding 6).

## Corrections to this document

1. **Finding 6, first draft** — used output tokens as the proxy for "tokens per exchange" and wrongly concluded the regression was an instrument artifact. Output is <1% of spend and is not what result-interception compresses. Retracted and rewritten around per-turn context growth.
2. **Ranked action #1, first draft** — "shorten sessions" was presented as the only lever on the dominant term. Incomplete: per-turn growth and session length multiply. Halving the increment is worth as much as halving the length, and unlike session hygiene it can be automated by a hook layer.

## Finding 8 — the hook surface survived intact; the nexus removed its teeth

The reported loss was "I expanded the surface of the various hook types, and that got median tokens/turn down, but it was rewritten into the nexus." Checking four config generations, the **surface is byte-identical throughout** — pre-nexus (07-21 23:57), routing (07-22), peak nexus (07-23), last-live (07-24):

```
PreToolUse    PowerShell|Bash|Cmd|Read|Grep|Glob|WebFetch|Agent|mcp__
PostToolUse   PowerShell|Bash|Cmd|Read|Write|Edit|NotebookEdit|Glob|Grep|TodoWrite|
              TaskCreate|TaskUpdate|EnterPlanMode|ExitPlanMode|Skill|Agent|
              AskUserQuestion|EnterWorktree|WebFetch|mcp__
PreCompact / UserPromptSubmit / SessionStart / Stop    *
```

That 20-name `PostToolUse` list is clearly hand-built, well beyond any default. **It was not lost. It is recoverable verbatim** from `.backups/context-mode-routing-backup-2026-07-23T06-49-13Z/.claude/settings.json`.

What changed is what runs behind the matchers.

**Original single-client wiring** (`~/.claude/settings.json.bak`, 05-20) pointed each event directly at upstream's own handlers: `pretooluse.mjs`, `posttooluse.mjs`, `precompact.mjs`, `userpromptsubmit.mjs`, `sessionstart.mjs`.

**Nexus wiring** (07-21 onward) routes every event through `runtime/hook-runner.mjs --client claude <event>`, and that path applies:

```
infrastructure.json:19        "mode": "advisory"
client-config.mjs:101         routingMode: infrastructure.governance.routing.mode
custom-routing.mjs:92-93      function applyTokenRoutingMode(config, decision) {
                                if (config.routingMode !== "advisory" || !decision) return decision;
```

`applyTokenRoutingMode` **downgrades a routing decision from a blocking `deny` to a non-blocking nudge.** In the original setup a PreToolUse routing decision was enforcement — the raw `Read`/`Bash` was refused and the call had to go through the sandbox, so the full output never entered context. Under advisory it is a suggestion the model is free to ignore, and does.

This matches the recorded symptom exactly: five PreToolUse nudges fired in the exhibit session, every one ignored, `total_calls: 0`. Same surface, same matchers, same firing rate — zero interceptions.

**Corollary worth separating carefully:** the shared-store contention (PID-sharded stats, split session rows, 135 shards) corrupted the **instruments**, not the savings mechanism. Savings came from `PostToolUse`/`PreToolUse` interception; the store damage broke `ctx_stats`' ability to report it. Those are independent failures that arrived together, which is why they read as one.

### The cheap experiment

Restoring the savings does not require the nexus, a rebuild, or resolving any of the client-agnosticism work:

1. Take the preserved expanded matcher surface from the 07-21 backup.
2. Point the commands at upstream handlers directly — `node/node_modules/context-mode/hooks/{pretooluse,posttooluse,precompact,userpromptsubmit,sessionstart}.mjs` — as `settings.json.bak` did, bypassing `hook-runner.mjs` and therefore `applyTokenRoutingMode` entirely.
3. Measure Δcontext/turn with `measure-context-floor.ps1`.

If per-turn growth drops from ~2,100 back toward ~1,300, the mechanism is confirmed and the attribution question in Finding 6 is settled empirically rather than argued.

Two caveats, stated up front:

- **Blocking mode needs the server live.** A hard `deny` on `Read`/`Bash` while `ctx_*` tools are unreachable hard-blocks both paths — the exact trap identified in the exhibit. Gate the deny on server reachability, or accept that a server failure degrades to a stall.
- **Upstream handlers still write the shared store** that codex and antigravity write to. That reintroduces the stats/session corruption but not the token cost — and you now measure from harness records instead, so a broken `ctx_stats` no longer hides anything.

Also on disk and not yet read: `context-mode-core/issues/claude-broken-tools-context-bloat.md` (5,446 B), which by its name documents the original context-bloat work directly.

## Finding 9 — three more savings holes, from `issues/`

`claude-broken-tools-context-bloat.md` is a partial snapshot of the exhibit conversation (first two exchanges) — nothing new. `claude-setup-problems.md` and `claude-setup-notes.md` are different documents and contain three items that belong in the rebuild spec.

**9a. "Hooks that log-and-no-op rather than block the host" was reviewed as a virtue.**

`claude-setup-notes.md:30` lists it under "what's genuinely good," alongside dry-run defaults and atomic writes. It is the same defect as advisory mode, one level up: expressed as a design principle rather than a config value. A hook that cannot block cannot intercept, and interception is the entire savings mechanism.

The tension was never named, so it was never traded off deliberately:

| goal | requires |
|---|---|
| never destabilize the host | hooks no-op on any doubt |
| keep tool output out of context | hooks deny the expensive call |

These are in direct opposition. A rebuild has to state which wins under which conditions — e.g. block when the sandbox is reachable and the payload exceeds a threshold, no-op otherwise — instead of letting "safe" silently win everywhere.

**9b. `offset`/`limit` on Read is a routing bypass.** `claude-setup-notes.md:21`:

> `structuredFileDecision` hard-denied any Read of a >250KB structured file on size alone in that revision. **The current implementation skips routing when offset/limit are present.**

A usability complaint (bounded reads were being denied) was fixed by exempting bounded reads from routing entirely. That hole is large: `offset`/`limit` bound *which* bytes are read, not *how many* tokens land in context.

Demonstrated in this session. Two reads of the same discussion file:

```
Read (no offset/limit)          → 21,961 tok      would have been routed
Read (offset=642, limit=560)    → 20,551 tok      would have been EXEMPT
```

The exempt read cost as much as the routed one. The correct fix is to keep bounded reads *permitted* but still subject the **result** to size-based compression — decouple "may this call proceed" from "how much of its output enters context." Conflating those two is what forced the false choice.

**9c. What the expanded surface actually bought — worth preserving.** `claude-setup-problems.md:8` records the behaviour when it worked:

> PreToolUse fired on every one of my tool calls — and the tips are tool-aware (the PowerShell call got host-shell guidance, Grep got match-aggregation guidance, Read got the Edit-vs-analyze distinction).

Per-tool adaptive guidance, not one generic nudge. That is the payload of the surface expansion and the thing to port forward.

**9d. Historical footnote, resolved.** `claude-setup-problems.md` documents an earlier failure with the same signature but a different cause: hooks fully live and injecting, `mcpServers` registration entirely absent, so every tip named a tool that did not exist. Same end state — "injecting guidance without capability" — reached twice by different routes (missing registration, then deferred tools, then advisory mode). Three distinct causes, one symptom. Any replacement should make "advertise only what is callable right now" an invariant rather than something re-broken each time.

## Finding 10 — the policy has no category for interpretive reading, and the metric can't detect the damage

This is a **quality** defect, not a cost defect, and it is the motivation behind the customizations rather than a consequence of them.

`skills/context-mode/SKILL.md` routes on an **edit-vs-analyze** axis. The decision tree's terminal branch is a catch-all:

```
└── Reading a file to analyze/summarize (not edit)?
    └── Use ctx_execute_file (file loads into FILE_CONTENT, not context)
```

Reinforced at line 40 ("When uncertain, use context-mode") and line 150 ("For files you need to EDIT: Use the normal Read tool. context-mode is for analysis, not editing"). So any file read that is not an edit falls through to sandboxed extraction returning a ~200 B summary.

Every worked example is **extractive**: parse `access.log`, analyze CSV/JSON/YAML/XML, count functions, find patterns, extract metrics. Every automatic trigger is extractive: API responses, logs, test output, git history, data inspection, infrastructure listings.

**There is no cell for reading a specification, a design document, an argument, or prose you must reason about.** Not handled badly — absent from the taxonomy, and swallowed by a data-shaped default.

### Why this produces confabulation specifically

`ctx_execute_file` requires writing code that extracts something, which requires already knowing what you are looking for. For a log you do — "count the 500s." For a document you have not read, you do not; discovering what is in it *is* the task. So you write a generic extractor (grep the headings, print the first N lines), get back a skeleton, and end up holding the document's **shape with none of its content**.

That is the exact state that generates confident speculation. Knowing the section titles is enough to talk fluently; not having read the argument means what you say is generated rather than recalled. The policy doesn't cause carelessness — it systematically produces the informational precondition for it.

### This session is the controlled demonstration

Three findings drove everything useful here: advisory mode downgrading `deny` to a nudge; the `offset`/`limit` routing exemption; "log-and-no-op rather than block" reviewed as a virtue. Each is **a single line inside a 1,185-line document**. No `summary_prompt` written in advance would have retained them, because none of them was what I was looking for. The 42,512 tokens spent reading in full is the reason this document exists.

Cost-optimally, that read was the worst decision of the session. Under the only metric context-mode reports, routing it to a 200 B summary would have scored as a triumph.

### The structural root: a one-sided objective function

`ctx_stats` measures bytes kept out. **Information destroyed and tokens saved are the same number.** A metric carrying only that term will always prefer the option that discards most; it has no term that penalizes being wrong.

This is the same defect as "the report reads best exactly when routing does least" (Finding 6), one level deeper — not a rendering bug but the objective itself. **A savings-only optimizer is guaranteed to converge on dumbing-down.** No amount of engineering on the interception layer fixes it, because the layer is faithfully maximizing what it was told to maximize.

Any replacement needs a second term or it reproduces this pain point by construction.

### Design directions

1. **Route on reducibility, not edit-intent.** The question is not "will you edit this?" but "is the answer a small computable function of these bytes?" Logs, CSVs, test output, `git log` — yes, the payload is a tiny function of the volume. Specs, designs, prose, code under review — no, the information is distributed through the text. Same tool, different axis.
2. **Index is the third option the taxonomy skips.** Allow-or-deny is a false binary. `ctx_index` + `ctx_search` already exist and the tree reaches for them only for web docs and Playwright snapshots. For prose: admit an outline plus passages matching the live question, keep the rest addressable. Lossless-but-not-resident, versus a summary that is lossy-and-final. This is the same separation Finding 9b demanded — decouple "may the call proceed" from "how much stays resident."
3. **Interpretive reads need re-entry, not one shot.** `ctx_execute_file` is terminal: write extractor, get result, artifact gone. Comprehension is iterative — you learn what to look for by looking. Keep the artifact queryable across the turn.
4. **Instrument the failure so it stops being invisible.** Cheapest proxy: count how often a routed read is followed by re-reading the same artifact, or by a correction. A high re-read rate means the summary was inadequate. That is the missing second term, and it is measurable without new infrastructure.

### What to keep

The bluntness is *correct within its stated domain*. Every trigger in that list is genuinely reducible data, and for those cases a 200 B summary loses nothing. The defect is scope creep — a catch-all branch claiming territory the design never addressed. Keep the extractive path essentially as-is; add the interpretive path beside it rather than replacing anything.

## Finding 11 — the engine already supports the languages the playbook never mentions

`build/executor.js` handles considerably more than the guidance advertises:

```
executor.js:26    csharp: "csx"
executor.js:58    function isPowerShell(shellPath)
executor.js:62    function buildPowerShellScriptContent(code)
executor.js:63    // Prefix a UTF-8 BOM so Windows PowerShell 5.1 reliably detects the script
executor.js:272   language === "go"      executor.js:276  language === "php"
executor.js:280   language === "elixir"
```

47 `csharp`/`dotnet` references across the package. PowerShell gets dedicated handling — shell detection, a `-File` special case, BOM emission for PS 5.1 — which is more care than an afterthought receives.

The playbook covers **none of it**. `references/` contains exactly three files: `patterns-javascript.md`, `patterns-python.md`, `patterns-shell.md`. Measured on `patterns-shell.md`:

```
powershell/pwsh/Get-*/$env: mentions      0
bash-isms (grep/awk/sed/#!/bin)          22
worked examples                          Jest, Pytest, tsc
```

So in a PowerShell-and-C# environment, running on Windows, the guidance layer describes a toolkit the user does not use while staying silent about the two languages they do — **even though the sandbox executes both**. The likely practical consequence is a capability that has been available and unused.

This also corroborates the original impetus: *"initially I didn't even get savings because hooks caught nothing in my environment."* That reading is supported from two directions — `claude-setup-notes.md:22` records that the Claude `PreToolUse` matcher **omitted `Bash`** in the shipped deploy, and the guidance was bash/JS/Python-shaped throughout. On a Windows PowerShell host, the matchers missed the tools actually being called and the playbook described the wrong shell. Expanding the matchers to the tools Claude actually invokes was the correct diagnosis and the correct first fix.

### The design point: catalog + trigger-selected fragments

The objection — heuristics and language patterns should not be broadcast; a catalog should be surfaced and playbook elements exposed per hooked trigger — is architecturally sound and cheaper than it sounds, because **the hook already holds the selection key.** At `PreToolUse` it knows the tool invoked, the command text, the target file extension, the shell family (`detectShellFamily`, already built), and the project composition.

That is sufficient to select a fragment. The architecture is playbook fragments keyed by `(language | tool | task-shape)`, retrieved at hook time and injected as the nudge payload — instead of a fixed three-language reference set authored months earlier for someone else's stack.

Note this is **not** a savings-versus-quality tradeoff. Static broadcast is dominated on both axes: resident cost falls to a catalog pointer, and what does arrive is selected by the call actually being made. That is the "enhance reasoning while saving tokens" case, and it holds because relevance and volume are being optimized by the same move.

Fairness to upstream: `references/` files are read on demand by skill convention, not auto-injected, so resident cost is not the main charge. The charge is **catalog composition** (three languages, none of them the user's) and **absence of trigger-driven selection**.

### The unifying primitive

Findings 10 and 11 are the same mechanism applied to two layers:

| layer | current | wanted |
|---|---|---|
| **content** being read | summarized to ~200 B, lossy and final | indexed, addressable by the live question |
| **guidance** about reading | broadcast catalog, fixed at author time | indexed, selected by hook-time trigger context |

One primitive — *retrieval keyed on live context* — serves both. That is a stronger unification claim than the earlier "context-mode + Meterless + codument" question was able to reach, because it names a shared substrate rather than a shared theme: capture an artifact, index it, retrieve fragments by relevance to the current moment. Guidance is just another indexed corpus whose query is the hook event.

## Finding 12 — compaction is a family of type-specific operations, not one verb

The harness ships a working model of the architecture being argued for. `~/.claude/.aghado01/tools/shell-snapshots/*.sh` (6 files, 14 KB, regenerated per session) versus `~/.claude/.aghado01/skills/context-mode/**` (5 files, 52.7 KB, a byte-identical copy of the package payload):

| | shell snapshot | context-mode skills |
|---|---|---|
| origin | derived from the live machine | authored once, shipped |
| capability | **probes** (`if ! command -v rg`) then shims | asserts |
| policy delivery | **implemented** — `pkill` shadow fails the call with the fix inline | described in prose, hoped for |
| when guidance appears | only on violation | every session, unconditionally |
| resident cost | 0 tok — lives in the shell | 52.7 KB of markdown |
| staleness | re-derived each session | fixed at author time |

The `pkill` shadow is the sharpest instance: rather than a rule to remember, the dangerous call returns `refusing to run — this pattern matches the Claude CLI process (PID %s). Narrow the pattern, or target your own children with 'pkill -P $$ ...'`. Precise, actionable, and delivered at the only moment it is relevant.

### Compaction by type

"Summarize" is the wrong verb for every content type, because it is lossy in an uncontrolled direction. Each type has a natural decomposition that is **lossless at some level**, and the operation should be to admit the level the question needs while keeping lower levels addressable:

| content | operation | fidelity guarantee |
|---|---|---|
| console / log output | **dedupe + count** — collapse repeats to `N×`, keep first/last, preserve non-conforming lines | anomalies preserved; anomalies are the information |
| structured data (JSON/CSV/XML) | **schematize** — schema, cardinalities, value distributions, N representative rows | shape and outliers exact; bulk addressable |
| code | **fold** — imports, declarations, signatures, call-graph edges; bodies collapsed, expandable | lossless at signature level |
| markdown / prose | **excerpt-with-anchor** — heading tree plus verbatim passages matching the live question | admitted text is verbatim, never paraphrased |
| diffs / patches | hunk headers + changed lines | context lines recoverable from the file |

Note that paraphrase is excluded everywhere. Paraphrase is the specific step where confabulation enters (Finding 10); excerpting preserves verbatim fidelity for what is admitted and addressability for what is not.

**This is where the "enhances reasoning" claim is literally true, not aspirational.** A folded code file is *easier* to reason about than the raw file — structure surfaced, noise gone. A deduped log with anomalies preserved is *better* input than the raw log; the earlier finding in this investigation was found exactly that way (`309× {healed:[],skipped:"no-plugin-root"}`). For several types, type-aware compaction is a quality improvement that happens to also be cheaper. That is the strong form of the argument, and it holds.

It also gives the second objective term teeth (Finding 10). "Lossless at signature level" and "anomalies preserved" are auditable properties. "Summarize" has no such property, which is why nothing could detect its damage.

### Two of these engines already exist in the workspace

This reduces "build a new system" to "wire components already owned behind a type-dispatch layer":

- **`reposnapshot`** is the code folder. Its stated ingest discipline — *tolerate broken code, under-strip, never corrupt* — is precisely the fidelity guarantee the fold operation needs, and its MCP end-goal is the delivery mechanism.
- **`jso-jackson`** is the JSON/JSONL handler, already the designated tool for structured data in this workspace, already slated for MCP exposure.

What is missing is the **dispatcher** — the hook-time decision of which operation applies to this artifact for this question — plus the log-dedupe and prose-excerpt operations. That is a materially smaller build than a context-mode replacement, and it lands the type-specific handling the current system reduces to one blunt verb.

## Design note — engineering the filters

The stated challenge is that pre-context filtering is situation-dependent. Six constraints make it tractable without requiring the filter to be clever.

**1. Prefer operations with an inverse.** Safety comes from *reversibility*, not from judgment. `309× <pattern>` plus a handle to retrieve the 309 costs a round trip when wrong; a summary costs the answer, silently. Reversible operations can be tuned aggressively because aggression is cheap when recoverable. This is `reposnapshot`'s *under-strip, never corrupt* generalized: the error costs are asymmetric — over-retention costs tokens, over-stripping costs correctness and hides that it did — so tune to the asymmetry, never to a midpoint.

**2. Filter on form, never on meaning.** Reliable filters are syntactic: exact-or-normalized line equality, lines appearing in >N% of the corpus, known frames (license headers, stack-trace preambles, ANSI escapes, progress-bar redraws). All decidable without understanding content. "This paragraph seems unimportant" is a semantic judgment and is where filters destroy signal.

**3. The normalizer is where the engineering actually lives.** Dedup is trivial; deciding that two lines are "the same" is not. Collapsing 359 heal-log lines to `309× {healed:[],skipped:"no-plugin-root"}` required masking timestamps first. A shared normalizer — mask timestamps, PIDs, GUIDs, hashes, paths, line numbers, addresses — is the reusable primitive underneath every type. Too weak and duplicates are missed; too strong and distinct events merge. Build and test this before any operation that depends on it.

**4. Retention inversely proportional to frequency.** Naive truncation keeps the head; in logs the signal is a rare line in the tail of the frequency distribution. Invert it: high-frequency collapses hard, unique lines survive verbatim. Uniqueness is a computable proxy for information content, and it is why dedup *raises* signal-to-noise rather than merely shrinking volume.

**5. Decide at PostToolUse, not PreToolUse.** At `PreToolUse` the output is a prediction; at `PostToolUse` it is in hand and its compressibility is *measurable* — repetition ratio, type, entropy — before anything is discarded. Measure, then act. This is the same separation Finding 9b demanded: `PreToolUse` owns "may this call proceed," `PostToolUse` owns "how much of its output becomes resident."

**6. A no-op floor, and determinism.** If the operation saves less than some threshold (~20%), emit raw — mangling without benefit is pure loss. And compaction must be deterministic given `(payload, type, question-class)`, or the same artifact renders differently across turns, invalidating cache and confusing recall.

### Worked example: grep results

Grep is a good case because naive dedup actively destroys the signal — identical matching lines in *different files* are the finding, not redundancy. Key on `(file, line, content)` and never collapse across files.

But inversion does better than filtering. Instead of a flat list:

```
raw        487 lines of file:line:content
inverted    12 distinct match shapes, each with count + file list + one exemplar
```

Smaller *and* better organized — the distribution across files becomes visible where the flat list buried it, and any shape expands back to its members. That is the pattern to aim for throughout: the compaction that wins is usually a **restructuring**, not a truncation.

### What the situation actually depends on, and where each signal comes from

| decision input | source | cost |
|---|---|---|
| content type | extension + sniff | free |
| extractive vs interpretive request | the user's prompt text, available at `UserPromptSubmit` — a hook already wired | free |
| repetition / compressibility | measured on the payload at `PostToolUse` | one pass |
| whether it worked | re-read rate (Finding 10) | post hoc |

None requires the dispatcher to be smart. It requires it to be positioned where the inputs exist — which is the actual architectural claim, and why `PostToolUse` interception is the crown jewel rather than `PreToolUse` advice.

### Navigable views — results as addressable objects

The stronger form: don't transform the payload once, make it a **handle** the model pages through. `PostToolUse` stores the 487-line grep result server-side and returns a view plus navigation affordances; each drill-down is a cheap call returning another small view. Nothing discarded, no firehose, depth on demand.

This directly addresses Finding 10's failure mode — superficial acquaintance breeding speculation — because the model can *go get* what it lacks instead of inventing it. It also produces a free fidelity signal: what the model paged into is evidence of what mattered.

The harness already ships the crudest possible version of this, and it worked on this very session:

```
[Truncated: PARTIAL view — showing lines 1-641 of 1185 total (39267 tokens, cap 25000).
 Call Read with offset=642 limit=641 for the next page…]
```

~105 tokens, told me exactly how to continue, nothing lost. It is linear and structureless — no preview, no shape, no targeting — but it is the right skeleton.

**The economics are counterintuitive and constrain the design.** Every page fetch is a full request, so it re-sends the entire conversation as cache read. At this workspace's median resident context (~120K), one page fetch costs ~120K cache-read tokens regardless of how small the page is. Fetching `k` pages costs roughly `k × C`. Admitting the whole payload once costs `payload × T` for the `T` remaining turns.

So paging wins only when the payload is large, the session still has many turns to run, **and `k` stays near 1–2**. Naive fine-grained paging is strictly worse than one medium dump. Two design consequences follow:

1. **The first view must be high-yield.** Page 1 should be the *restructured index* — all 12 match shapes with counts and file lists — not "lines 1–50." Restructuring and paging compose: restructure so the index fits one view, then drill once into the branch that matters. Linear pagination maximizes `k` and is close to the worst option.
2. **Coverage must be legible.** The view states `12 of 12 shapes · 40 of 487 lines shown`, so sufficiency is readable rather than guessed. Under-fetching causes confabulation; over-fetching costs more than the dump ever would. The model cannot calibrate what it cannot see.

Two further constraints:

- **Navigation affordances must be tiny and inline** — a footer like `[h7f3 · 12 shapes · 487 matches · expand: shape=N | file=path]` is ~20 tokens. Emitting a menu of options re-creates the broadcast problem at a smaller scale.
- **Handles must survive session re-keying** (which we established happens routinely). Key them on content hash, not process or session id — the same restart-tolerance requirement that fell out of the original investigation.

Worth noting: `ctx_index` + `ctx_search` is already this primitive upstream. The decision tree reaches for it only for web docs and Playwright snapshots, never for tool output. Same pattern as Finding 11 — the engine can do more than the policy asks of it.

### Prior art already in the workspace: the envelope and the verbs

Two existing artifacts implement complementary halves of the navigable-view design. Neither is a prototype — both are in use.

**`reposnapshot` tree manifest — the addressing layer.** `.snapshot/reposnapshot_20260723_035834/*_tree.md` is **2,476 B indexing ~270 KB across 5 shards** — a 1:110 portal-to-payload ratio. Its row format:

```
name <TAB> shard_index <TAB> row_offset <TAB> row_meta_end <TAB> row_content_begin <TAB> row_content_end
rs.core.sharding.psm1   s005   13380   13458   13462   54135
```

What it gets right, point by point against the constraints in the section above:

- **Targeted seek, not linear pagination.** Byte ranges make any entry O(1) reachable. `k ≈ 1` by construction — the economic constraint that kills naive paging is designed out rather than mitigated.
- **Two granularities per entry.** Separate `meta` and `content` ranges, so metadata can be fetched without the body. A refinement absent from the sketch above.
- **Structure preserved as navigation.** The directory tree *is* the index. Restructuring, not truncation.
- **The hazard is anticipated inline:** *"Do not use grep to search the data because it will return an explosion of duplications."* — the exact grep-dedup failure mode identified independently above.
- **Policy implemented through structure:** *"The shard files are intentionally .txt to encourage use of lower level tools like `read_file` instead of json tools."* The shell-snapshot principle (Finding 12) applied to artifact design — steer by shaping the object, not by asking.
- **The design intent is stated in the artifact itself:** *"manage 'firehose' context overload by selectively seeking segments of the payload file iteratively over multiple inference cycles."*

**`jso-jackson/jso-debug.ps1` — the verb set.** 1,128 lines factoring exactly the navigation vocabulary that Finding 12's type table calls for:

| function | operation |
|---|---|
| `Format-JsonlSchema` | schematize — one row per JSON path |
| `Show-JsonlStructure` | per-field structure row for one record |
| `Get-JsonlSample` | representative rows |
| `Get-JsonlContext` | `-At N -Context K` — neighbourhood around a hit |
| `Format-JsonlRecord` | render one record |

**The two are complementary, and neither is complete.** `reposnapshot` has the addressing but a fixed verb (fold code). `jso-debug` has the verbs but no addressing layer — it is record-index based; `row_offset`, `Shard`, `ByteOffset` appear **zero** times in it.

### The generalization

Every type in Finding 12's table produces **the same envelope**: a small manifest of addressable entries with ranges into a larger payload.

| type | manifest entries | ranges point to |
|---|---|---|
| code | file / symbol tree | signature and body spans |
| structured data | JSON paths, schema rows | record indices |
| logs | distinct shapes with `N×` counts | member line spans |
| grep | match shapes with file lists | individual hit spans |
| prose | heading tree | section anchors |

So the architecture is one envelope plus N type-specific **packers**. `reposnapshot` proves the envelope on code; `jso-debug` proves the verbs on JSONL. This is materially further along than "build a context-mode replacement" implies.

### What is genuinely missing

1. **Automatic generation at hook time.** Both tools are user-invoked, batch, over *persistent artifacts on disk*. The rebuild needs the identical envelope produced automatically at `PostToolUse` over **ephemeral tool output that has no file** — which also implies a store for transient payloads with content-hash handles that survive session re-keying.
2. **The addressing layer ported into the data verbs** — `jso-debug`'s operations emitting offset ranges rather than record indices.
3. **The dispatcher** — selecting the packer from type plus question-class.
4. **Two packers not yet written** — log dedupe and prose excerpt.

### Descriptive vs. prescriptive guidance — the distinction that resolves the enforcement question

An earlier draft of this section called the tree manifest's instruction block "advisory guidance" and grouped it with the failed `PreToolUse` nudges. That was wrong, and the correction matters for the whole design.

The manifest's text is **descriptive** — it says what the object *is*:

| text | kind |
|---|---|
| `name<TAB>shard_index<TAB>row_offset<TAB>…` | pure self-description; the offsets are meaningless without it |
| "Treat this payload like a virtual database … byte offsets available for random-access" | states the affordance model — seeking is not discoverable otherwise |
| "manage firehose overload by selectively seeking … over multiple inference cycles" | explains a capability and its use |
| "Do not use grep … it will return an explosion of duplications" | warns about a non-obvious property of the substrate |
| "shard files are intentionally .txt to encourage lower level tools" | explains a design decision so the extension is not misread |

None of it is "prefer tool X over tool Y." It is information about the world, and **information does not need enforcement — it needs accuracy.** Once a reader knows the payload is byte-addressable and that grep will explode on it, seeking is self-evidently correct. No policy layer is required to produce the right behaviour.

Context-mode's nudges were **prescriptive**: preferences about behaviour, asserted without the information that would make them evident, and naming tools that were frequently uncallable. That is why they degraded to noise while the manifest's text does not.

| | descriptive | prescriptive |
|---|---|---|
| content | what this is, how it is addressed, what will surprise you | do this, prefer that |
| requirement | accuracy | enforcement |
| failure mode | becomes stale/wrong | becomes ignorable |
| scales with | the substrate | the policy author's foresight |

**Design principle: prefer making the right action evident over making it mandatory.** A self-evident substrate produces good behaviour without a policy layer at all.

This revises what the hook layer is *for*. Not a cop — a **fabricator**. Ephemeral tool output has no manifest unless something interposes to build one. The hook's job is to turn a firehose into a self-describing substrate, attached to the payload at the moment of contact rather than resident as a policy block. The agent then behaves well because the object is legible, not because it was instructed.

It also resolves Finding 10 from the other side. Confabulation happens when an agent holds shape without content *and has no way to see what it is missing*. A self-describing view states `12 of 12 shapes · 40 of 487 lines shown` — making the agent's own ignorance visible to it. That is protection against inherent blindness, and it is descriptive, not prescriptive.

**Where enforcement still belongs:** the `pkill` shadow (Finding 12) is genuine enforcement — but note it is also self-documenting, returning *why* and *what to do instead*. The rule is not "never enforce," it is **enforce where errors are irreversible; make evident where errors are merely costly.** That maps onto the reversibility principle in the design note above: irreversible destruction of the CLI process warrants a hard block; an over-large tool result warrants a legible substrate.

### The unification: one substrate contract, two existing implementations

`jso-jackson.ps1` (2,425 lines) is a **schema-agnostic JSONL engine**, and its class list is the same architecture as `reposnapshot` reached from the other direction:

```
JsonlIndex       binary seek index (.jidx) — magic "JSOI" + version + lineCount + int64[offset]×lineCount
JsonlSchema      derived path/type/coverage map — structure recovered from schemaless data
JsonlTraversal   fluent filter/extract, stays in System.Text.Json (no PSCustomObject in the read path)
JsonlFile        mount point factory — binds a snapshot + index for traversal
New-JsonlSnapshot   Phase 1 ingest: copy to working dir, LF-normalize, tail-validate, build .jidx
Bloom filter     probabilistic membership, no false negatives, paired with exact HashSet
```

Plus a stated design contract that is exactly the envelope/packer split argued for above: *"This file is NOT a user-facing entry point. It is consumed by domain-specific subclass files (e.g. `claude-jso-jackson.ps1`) that add schema knowledge and domain output."*

#### Side by side

| concern | reposnapshot | jso-jackson |
|---|---|---|
| immutable snapshot | `.snapshot/<ts>/` | `New-JsonlSnapshot` → working dir |
| normalization | content processors — `rs-psstrip`, `rs-csstrip`, `format-ws`, `rs-indent` | structural — LF, tail validation |
| container | **N shards**, `MaxShardSpanBytes`, packing/grouping strategies | single snapshot file |
| positional index | byte ranges inside the human-readable manifest | **`.jidx` binary sidecar, O(1) seek** |
| addressing unit | file / symbol, meta range + content range | line / record |
| structural index | directory tree — *given* by the filesystem | **`JsonlSchema` — *derived* from the data** |
| identity | `rs.core.hash`, `rs.core.lsh` | content fingerprint + **Bloom + HashSet hybrid** |
| query surface | seek to offset | `JsonlTraversal`, `Select-JsonlPath` |
| mount abstraction | implicit | **`JsonlFile`** |
| domain layer | repo *is* the domain | **subclass files** (`claude-jso-jackson`) |
| self-describing portal | **`tree.md` with orientation** | none — interface is a PowerShell API |

The strengths are close to disjoint. `reposnapshot` owns sharding, content-transforming normalization, and the agent-legible portal. `jso-jackson` owns the binary index, derived structure, identity/dedup layers, the mount abstraction, and the engine/domain split.

#### Provenance correction, and what it actually means

An earlier draft called the missing `.jidx` portal a *gap* and an instance of agent blindness. That was wrong on the history. `jso-jackson.ps1` and `jso-hash.ps1` were written as agnostic primitives **behind** `claude-export`; `.jidx` sidecars were a **performance** measure, built for every JSONL IR along the export pipeline. Their consumer was the next pipeline stage, not an agent. No portal was needed because no agent was reading them. `jso-debug` came later — an afternoon's work assembled from primitives that already existed.

So the observation is not a design flaw, it is **convergent structure**: primitives built for pipeline throughput turn out to be exactly what agent navigation requires. Content-addressed, offset-indexed, staged, immutable — the same properties serve both readers. That `jso-debug`'s navigation verbs fell out in an afternoon is evidence the substrate was right, not that the verbs were an accident.

The two artifacts are therefore optimized for different readers — engine vs. agent — and each carries what the other lacks. `tree.md` is linear and positional-only (readable, but scanned rather than seeked, no derived structure or identity layer); `.jidx` is O(1) and multi-layered but opaque without prior knowledge. Neither is wrong for its own consumer. The convergence opportunity is that the *agent* is now a consumer of both.

#### The export pipeline is the real prior art

`claude-jso-jackson.ps1` is a staged-lowering compiler with an addressable artifact at every stage:

```
Phase 0  Discover      sentinel moonwalk → full fragment chain
Phase 1  Snapshot      each source file → raw/, each with .jidx
Phase 2  Traverse      filter, dedup, annotate, merge
Phase 3  Merge         unified JSONL + .jidx
         Group         Get-ClaudeExchanges → exchange units
         Render        Merged | Exchanges | Markdown
                       × Diarized | Dialogue | Structural | House
                       × exclude: thinking | tool-calls | tool-results | subagents
```

This is more complete than either the manifest or the verb set, because it demonstrates the whole shape: **ingest → normalize → staged IRs, each indexed → many renderings from one IR.** The "views" argued for throughout this document — schema view, sample, context window, page — are precisely *flexible renderings over a common IR*, and the type-specific packers are *lowering stages*. The architecture already exists; it has only been applied to one content type.

Note especially that the render is already parameterized along **exactly the axes that govern token cost** — `tool-results`, `tool-calls`, `thinking`, `subagents` — and at four levels of structural fidelity.

#### The closing loop: this session — with a retraction

An earlier draft of this section used the exhibit's 42,512-token cost as an example of avoidable waste, and proposed inverting the export's default. **Both claims were wrong**, and the first contradicted this document's own Finding 10.

The facts: **a default export includes neither tool calls nor tool results.** The exhibit was *deliberately* exported with both, for debugging problems observed during the live thread. Those details were load-bearing — the process table with parent binaries, the stats-shard contents, the heal-log frequencies, the hook configurations, the session-id split. Much of the investigation rests on them.

So the default polarity is **already correct**: compact by default, maximal by explicit opt-in. There is nothing to invert. The expensive rendering was requested on purpose and was the right call.

Worse, the "40K saved with nothing lost" framing directly contradicts Finding 10, which argues that interpretive reading — where you cannot know in advance what matters — is exactly the case that must *not* be compacted, and which cites this same read as the reason the investigation produced anything. Using the largest number in the session as a waste example was reaching for a tidy conclusion. The 42,512 tokens were **correctly spent**.

What survives, and it is narrower:

**A portal adds re-entry, not first-pass savings.** The first interpretive pass over an unfamiliar document should be whole — that is Finding 10. The cost this session actually incurred that a portal would have addressed came *after*: the file exceeded the read cap, so it arrived as `lines 1–641 of 1185` plus a truncation notice, and the second half required a separate offset fetch. That second read *was* a page fetch against a linear, structureless index. An exchange-level index with offsets would have made re-entry targeted — jumping back to exchange 7 without rescanning — which is a real cost this session paid.

**Per-unit depth beats global flags, specifically for the debugging case.** `-Exclude tool-results` is all-or-nothing across the export. When debugging, the useful shape is usually full fidelity for the three exchanges where something broke and prose-only for the other twelve. That is a per-unit selection the current flags cannot express, and it is additive rather than a change of default:

```
opus-173b3b46.portal.md          ~500 tok
  15 exchanges, titles + sizes + byte offsets into merged.jsonl
  per-exchange depth: prose | +tool-calls | +tool-results
  seek: Get-JsonlRecord -At <n>   re-render: -Format X -Exclude Y
```

The general lesson is the one this exchange demonstrates rather than the one it was first pressed into: **a savings framing will reach for the biggest number and call it waste.** That is the one-sided objective function (Finding 10) operating on the analyst rather than the tool. The correct question is never "how large was this read" but "was the information admitted worth its cost" — and here it plainly was.

#### The generalized contract

```
substrate = immutable snapshot
          + normalization        (structural | content-transforming)
          + container            (single | sharded)
          + index stack          (positional | structural | identity | probabilistic)
          + query surface
          + self-describing portal   ← declares which of the above exist and how to address them
```

The portal is the missing keystone: **a manifest that describes its own index stack.** It declares which indices exist, what each is keyed on, and how to seek through them. Then an agent meeting *any* snapshot — code, JSONL, log, grep result, prose — reads one small self-describing header and knows how to navigate, without prior knowledge of which tool built it.

That reframes the hook layer's job precisely. `JsonlFile` is named exactly right: a **mount point**. What `PostToolUse` should do with ephemeral output is **mount it** — snapshot, normalize, index, and emit the portal — then return the portal instead of the payload.

#### Don't merge the projects; extract the contract

The instinct to unify is right, but merging the products would be wrong, and for the same reason the nexus separates client-agnostic core from client-specific adapters. `reposnapshot` is a code tool and `jso-jackson` is a JSONL tool; both are legitimately useful standalone, with different users and lifecycles.

What should be extracted is the **substrate contract** above, with each project becoming a packer that implements it — `reposnapshot` for code, `jso-jackson` for JSONL — and the two missing packers (log dedupe, prose excerpt) written against the same contract. The shared deliverables are the portal format and the index-stack vocabulary, not a merged codebase.

Practical first move: give `.jidx` a portal, and give `tree.md` a declared index stack. Those two changes are small, independently useful, and they converge the formats without either project absorbing the other.

### Open question: foreign markdown → the Exchanges envelope

The goal is to ingest structural-markdown chat exports from other applications into the same JSONL exchanges envelope `claude-export` produces, so foreign threads gain identical affordances. `doccer` (ideated, not built; design in `reposnapshot/issues/grok-open-code-review-reposnapshot-doccer.md`) is the candidate.

Doccer's Chunk IR is a good fit by shape — it is explicitly JSONL-friendly and already carries the addressing this document has been arguing for:

```json
{ "id": "md-00042", "type": "paragraph|section|code_block|table|list",
  "path": ["# Title", "## Architecture", "### Collector"], "level": 3,
  "start": 1420, "end": 1893, "text": "...",
  "attributes": { "char_count": 473, "entropy": 4.12, ... },
  "children": [...], "parent": "md-00041" }
```

Offsets into the immutable original, heading ancestry as logical path, optional attributes, flat-or-tree emission. Same substrate contract as `.jidx` and `tree.md`, reached a third time.

#### Correction: threadparser is yielded by the engine, not layered on it

An earlier draft of this section proposed a downstream **per-source adapter stage** — doccer emits domain-free chunks, then an adapter maps them to Exchange records — and asserted that "doccer solves threadparser end to end" was unachievable because no format-agnostic method can identify a user turn.

That was wrong, and `doccer/legwork/` says so directly:

```
README.md:23  inventory.jsonl — Seed pattern library. Universal atoms, markdown layer, threadparse…
README.md:28  Orchestration rule tables (Phase 3 — ThreadParserRules, PdfMathRepairRules, etc.)
README.md:29  Output emitters (JSONL shards, manifests — already shaped well by threadparser-v2, port forward)
README.md:37  …five threadparser iterations in ps.core.reposnapshot/rs.core/threadparser/
SCHEMA.md:20  provenance — links back to a discussion thread or threadparser iteration
SCHEMA.md:72  dialect-specific patterns live in the pattern library
```

Threadparse is **already a layer in the seed pattern library**, beside universal atoms and the markdown layer. `ThreadParserRules` is an orchestration rule table sitting beside `PdfMathRepairRules`. The pattern entries are provenanced to five prior threadparser iterations — the specific application motivated the general engine, and the engine now re-yields it as one configuration among several.

**Why the distinction is architectural, not terminological.** Domain specificity enters doccer as *claims in the pattern library* and *rule tables*, both engine-internal data. Consequences a downstream adapter would forfeit:

- Turn boundaries participate in the **same interval algebra** as headings and fences — containment, nesting, and precedence resolve uniformly, so a turn can contain a fence and the geometry knows it.
- Multi-claim conflict resolution is free: when `---` is simultaneously a thematic break and a turn separator, the algebra arbitrates. An adapter would special-case it.
- Format variation is handled exactly like markdown dialect variation (`SCHEMA.md:72`) — as pattern data, not code. Chat-export formats are just another dialect axis.

The claim "no format-agnostic method can know this is a user turn" conflated **mechanism** with **data**. The mechanism — claims plus algebra — is fully format-agnostic; the pattern entries are data within it. That is what makes the engine-first bet pay: one engine, and threadparse, PDF math repair, markdown chunking, and the structured-prose virtual database all fall out as pattern sets plus rule tables.

So the answer to the open question is **not** an adapter per source. Ingesting a foreign chat export is: add its markers as pattern-library entries, and extend `ThreadParserRules` to cover the shape. The Exchanges envelope is then an emitter concern — and `README.md:29` notes the emitters are already shaped well by `threadparser-v2` and slated to port forward.

`MarkPig` remains the schema authority for the envelope (`ExchangeBlock` unit, `TranscriptBlock` root), with `doccer` co-located under `MarkBrain/MarkPig/`. `VALIDATION-MATRIX.md` already exists in the legwork set, so validation is a designed concern rather than something to bolt on — worth pointing at Claude's own exports first, since that is the one source where both the markdown path and the JSONL path exist and can be diffed against each other for ground truth.

#### Measured: the H1 invariant, and why Grok is the hard case

**Claude export** (`opus-173b3b46…md`, 15 exchanges declared):

```
xid markers                        15
'# ' at line start, outside fences 15      ← invariant holds exactly
'# ' at line start, inside fences   0
fence delimiters                   148 (balanced)
```

The H1-delimits-exchange invariant holds perfectly, and `---` is redundant (16 occurrences, decorative). Note the in-fence count is 0 partly by luck of the rendering: `Structural` emits tool calls as JSON blobs, so PowerShell `#` comments sit inside JSON string escapes rather than at line start. A format that rendered commands as raw code blocks would produce in-fence H1s immediately — which is why fence masking stays necessary regardless of what this one file measures.

**Grok export** (`grok-open-code-review-reposnapshot-doccer.md`, 652 lines) — the same measurement, on a source with no structural export:

| claim | count | lines |
|---|---|---|
| `Thought for N` | **8** | 3, 113, 203, 296, 369, 433, 610, 785 |
| `# ` H1 | 5 | 1, 111, 201, 294, 365 |
| `N sources` | 4 | 109, 199, 363, 429 |
| favicon citation images | 12 | — |
| bold-only lines | 22 | section headers, not boundaries |
| `2 / 2` regeneration counter | — | 367 |

There are **8 turns and only 5 H1s**. Three user turns (L431, L608, L783) are bare paragraphs with no heading at all — the invariant degrades partway through the document, and `2 / 2` injects noise between an H1 and its response.

#### The generalizable move: claim the reliable role, derive the other as complement

`Thought for N` occurs **8 times for 8 turns** — a complete, machine-emitted assistant-turn-start marker, while the user-side marker is only 62% present. So do not attempt to recognize user turns at all:

```
assistant_start  := claim("Thought for \d+s")        // complete
assistant_span   := assistant_start → next user_start
user_span        := complement(assistant_span)        // interval algebra, not pattern matching
```

This generalizes beyond Grok. In most chat exports **one role carries a reliable machine-emitted marker** — thinking time, model name, timestamp, token count — while the human side carries only whatever the UI happened to render. Claim the reliable side; the other falls out as the gap. That is a complement operation over intervals, which is exactly what the algebra layer is for and exactly what a regex-per-format approach cannot express.

The noise claims (`favicon` runs, `N sources`, `2 / 2`) are **masks** — the same primitive as fence masking, applied to citation cruft instead of code. One mechanism, two uses.

Practical consequence for the pattern library: a Grok layer needs roughly three entries — one assistant-start claim, one citation-block mask, one regeneration-counter mask — and no user-turn pattern at all.

## Rebuild backlog — consolidated

Objective — settle this first, it constrains everything below:

1. **Two-term objective.** Savings alone is guaranteed to converge on dumbing-down, because information destroyed and tokens saved are the same number (Finding 10). Add a fidelity term before designing the mechanism.
2. **Route on reducibility, not edit-intent.** Extractive path (logs, data, test output) keeps the current blunt treatment; interpretive path (specs, prose, code under review) gets indexed and addressable instead of summarized (Finding 10)
3. **One primitive, two layers: retrieval keyed on live context.** Applies to file content *and* to the guidance corpus — playbook fragments selected by hook-time trigger context, not broadcast (Finding 11). Authoring PowerShell and C# fragments is the first concrete task; the sandbox already executes both

Mechanism, in priority order:

4. Blocking enforcement with an explicit, stated fallback rule (9a, Finding 8)
5. Separate "may the call proceed" from "how much output enters context" — one change kills both the offset/limit hole and the forced summary (9b, Finding 10)
6. Never advertise an uncallable route; verify reachability before emitting guidance (9d)
7. Per-tool adaptive guidance, preserved from the working surface (9c)
8. `PostToolUse` result interception as the crown jewel — it reaches the harness's own tools

Measurement, all of which failed silently:

9. Δcontext per turn from harness usage records, not self-reported counters
10. Re-read rate as the fidelity proxy — how often a routed read is followed by re-reading the same artifact (Finding 10)
11. No stored aggregates; append-only records keyed `(client, session, project, ts)`
12. Metrics must fail loud — the old renderer printed `100.0%` and `216311×` precisely when routing did nothing
13. Bound the report's own output — the preference extractor emitted ~70 unbounded rows, so the savings tool bloated context

Resident overhead, measured (Findings 1–4):

10. Project-scoped MCP servers ~3.6K each — 11.3K in `codex-scientiae`
11. `enableWorkflows` vs. the no-subagent policy
12. Not worth touching: `skill_listing` (app-bundled), `MEMORY.md`, `CLAUDE.md`

## What this means for the rebuild

The dominant cost term is `Σ(context size per turn)`, which is driven by two factors that multiply:

- **session length** — habit, no tooling required
- **per-turn increment** — automatable, and the thing context-mode's hooks attacked

A replacement that reproduces only the MCP tools (`ctx_execute` and friends) rebuilds the *visible* half and misses the mechanism. `PostToolUse` result interception is the crown jewel: it applies to the harness's own `Read`/`Bash`/`Grep` — tools you don't own — and needs no cooperation from the model. Preserve that seam above everything else.

Instrument it from day one with `Δcontext` per turn, sourced from harness usage records rather than self-reported counters. Target: ≤1,300 tok/turn median, the level already achieved on this machine.
