# Brief: does context-mode cause session-id rotation? (ablation protocol)

**Status:** RESOLVED on cause (§7d refutes context-mode from data on disk); OPEN on runtime impact
and on the real root cause. Baseline captured 2026-07-25 02:05; measurement run 2026-07-25 02:21–02:32.
**Goal:** find the **root cause** of the session-id rotation and transcript duplication documented
in [brief-redundant-session-ids.md](brief-redundant-session-ids.md) §8 — and, independently of
cause, determine whether it **degrades the agent's runtime experience or performance** (§5b).

The context-mode ablation below is one controlled step toward the first half, not the objective in
itself. Ruling it in or out narrows the search; it does not end it.

---

## 1. The ablation

At ~02:00 the user removed context-mode entirely from `C:\Users\azrie\.claude\settings.json`:
the `hooks` key is gone (previously `PreToolUse`, `PostToolUse`, `PreCompact`, `SessionStart`),
`enabledPlugins` is gone, and all skills were removed. Verified in place — `env` is down to
`CLAUDE_CODE_USE_POWERSHELL_TOOL`, `CLAUDE_CODE_SHELL`, `CLAUDE_CODE_GIT_BASH_PATH`, `CLAUDE_HOME`.

The app was fully quit before the hook removal, and again after.

### 1a. The ablation was incomplete — correction (2026-07-25 02:25)

**The ablation never actually removed context-mode.** `settings.json` was clean, but the
context-mode **MCP server registration lives in a different file** — top-level `mcpServers` in
`C:\Users\azrie\.claude.json`, not in `settings.json`. Removing hooks, plugins and skills left the
MCP server registered and running.

Confirmed live inside the ablation thread: `mcp__context-mode__*` tools (`ctx_search`, `ctx_index`,
`ctx_execute`, …) connected and became available at 02:21, and the per-project MCP log directory
recorded a fresh context-mode process launch at 02:21:02. So the run labelled "context-mode
removed" was executed **with context-mode's MCP server live**, and the hook/plugin/skill removal was
the only thing actually ablated.

**Second-order failure — the file is rewritten by the running app.** After the user removed the
`mcpServers.context-mode` entry from `.claude.json` at ~02:30, a re-read at 02:32 found the entry
**still present**, with `.claude.json` last written at **02:29:17** — the exact second the MCP log
recorded a context-mode reconnect for the live session. The running app persists its in-memory MCP
configuration back to `.claude.json`, so an edit made while the app is running is clobbered.

Consequence for any future ablation: **quit the app completely, then edit `.claude.json`, then
relaunch, then verify** that no `mcp__context-mode__*` tool appears and that no new file lands in
`…\claude-cli-nodejs\Cache\<cwd-slug>\mcp-logs-context-mode\`. Editing settings while the app runs
is not a valid ablation.

**This is now moot for the stated question.** §7d refutes context-mode as the cause outright from
data already on disk, so no corrected ablation run is needed to settle it. The correction is
recorded because the same trap will catch any future config experiment.

## 2. Baseline — the thread that surfaced this

Project dir `~/.claude/projects/D--aghado01-utils-jso-jackson`, one conversation, **5 files**:

| session | created | last write | bytes | lines |
|---|---|---|---|---|
| `88478329` | 20:57:22 | 21:18:23 | 683,754 | 260 |
| `6322c777` | 21:18:44 | 01:24:53 | 1,612,573 | 680 |
| `9c02752c` | 01:25:03 | 01:26:12 | 1,538,838 | 534 |
| `54204ab0` | 01:26:28 | 01:37:14 | 1,719,904 | 613 |
| `20ac496b` | 01:38:12 | 02:05:18 | 1,924,916 | 683 |

Rate: 4 rotations across ~5h, but 3 of them inside 13 minutes (01:25–01:38).

### 2a. Which boundaries are explained

Gap between one file's last write and the next file's creation:

| transition | gap | reading |
|---|---|---|
| `88478329` → `6322c777` | 21s | too short to quit and relaunch — **in-session rotation** |
| `6322c777` → `9c02752c` | 10s | **in-session rotation** |
| `9c02752c` → `54204ab0` | 15s | **in-session rotation** |
| `54204ab0` → `20ac496b` | 58s | consistent with the app quit the user described |

So three rotations are not attributable to restarts, and all three occurred with context-mode
hooks active. That is what makes the ablation informative: if rotation were purely a
quit-and-relaunch artefact there would be nothing to test.

### 2b. Standing correlation to re-check

Every in-session rotation so far coincides with a `[Request interrupted by user]` record orphaned
in the outgoing file — four for four. Suggestive, not established: interrupts were frequent in
this session, so the correlation may be incidental. **This is the main confound.** A quiet
ablation window proves nothing on its own, because "no interrupts" and "no context-mode" would be
indistinguishable.

## 3. Conditions in the chip thread — read before designing around them

A chipped thread does not inherit this session's environment. Confirmed by the user:

- **No interrupts.** The user will not interrupt the chip thread at all. The
  interrupt-correlation probe originally planned here is therefore **off the table** — do not ask
  the user to interrupt, and do not treat a quiet run as a controlled result.
- **Lower default effort level.** Fewer/shorter turns than this session unless the work is
  explicitly sized to compensate. Rotation was only ever observed under sustained multi-tool
  activity, so a short run risks a false null purely from insufficient exposure.
- **Permission mode defaults to manual, not bypass.** Every gated tool call raises a prompt that
  suspends the turn pending user approval.

That last point is the useful one. A permission prompt suspends a turn awaiting user input, which
is mechanically similar to an interrupt. If the trigger for rotation is *turn suspension* rather
than interruption specifically, permission prompts supply that trigger with no user action needed.
So manual mode is not merely a confound to tolerate — it is a **substitute probe** for the
suspension hypothesis, and it must be logged as an event class in its own right.

## 4. What the fresh thread must do

Run in a **new conversation** so its files are cleanly separable (grouping is by project dir +
first user prompt, so a distinct opening prompt suffices; same cwd is fine).

1. **Record the opening state**: live `$env:CLAUDE_CODE_SESSION_ID`, and the file list for the
   project dir with creation and last-write times, so the new thread's own files are identifiable.
2. **Do sustained tool work** — deliberately size the task to produce many tool calls across many
   turns, comparable to the 01:25–01:38 baseline window, and do not let the lower effort level
   shorten it. Idling proves nothing.
3. **Do NOT request interrupts.** See §3.
4. **Log every permission prompt**: what triggered it, timestamp raised, timestamp approved. These
   are the suspension events available in this run.
5. **Re-check the project dir file count after every permission prompt**, and at the end. A
   rotation immediately following an approval is the single most informative thing this run can
   produce.
6. **Log every app quit** with a timestamp, so restart boundaries remain separable from in-session
   rotations via the §2a gap test.

### Verdict conditions

| observation | conclusion |
|---|---|
| New session file, sub-45s gap, no app quit | **context-mode exonerated** — rotation is intrinsic. Decisive regardless of anything else. |
| Rotation immediately after a permission approval | exonerated, **and** supports turn-suspension as the trigger rather than interruption specifically |
| Permission prompts occurred, no rotation | weak evidence against suspension-as-trigger; still cannot separate context-mode from absence-of-interrupts |
| No permission prompts, no rotation, short run | **inconclusive** — insufficient exposure, not a result |

**This run exists to refute, not to support.** One rotation under ablation kills the context-mode
hypothesis outright, and that is the outcome worth chasing — so maximise exposure: long run, many
tool calls, many turns, many permission prompts. Do not economise.

A quiet run is simply not a result. It does not mean context-mode was the cause; it means the run
did not reach the conditions under which rotation was previously seen. Report it as such and say
how much exposure it actually got, so the next attempt can be sized properly.

## 5. Independent cross-check

Not a substitute for the ablation — a separate line of evidence that can also refute, from data
already on disk:

- context-mode-core's earliest file on disk: **2026-07-21**
- oldest transcript in `~/.claude/projects`: **2026-04-18**
- corpus already known to hold 132 redundant files across 35 multi-file conversations

**If any multi-file conversation predates 2026-07-21, context-mode cannot be the cause** — no
waiting, no confounds, no dependence on run length or permission behaviour. The grouping query is
already written (brief-redundant-session-ids.md §8g); it needs only a creation-date column and a
split on that boundary. Run it before or alongside the chip.

## 5b. The question that actually matters — runtime impact

Cause attribution is instrumental. The real concern is whether rotation and duplication degrade
the agent's runtime experience and performance, **regardless of what causes them**. That holds
even if context-mode turns out to be implicated, and even if rotation turns out to be intrinsic
and unfixable — the impact is worth knowing either way.

Four candidate effects, in descending order of suspected cost. All were observed or inferred
during the session that produced this brief.

**R1 — prompt-cache invalidation.** A rotation changes the request prefix: a new session id
appears in system reminders, and a `SessionStart` block is injected mid-conversation. Anthropic
prompt caching keys on an exact prefix, so a mid-conversation prefix change plausibly invalidates
the whole cached conversation and forces full re-processing of every prior token. On a long thread
this is the dominant cost — latency on the first turn after each rotation, and input-token spend
proportional to conversation length, paid once per rotation.
*Measurable:* wall-clock latency of the turn immediately following a rotation versus the
surrounding turns. Transcript records carry `timestamp`, so **this is measurable retrospectively on
the five files already on disk** — no new run required.

**R2 — MCP teardown and reconnection.** During the baseline session the context-mode MCP server
disconnected and reconnected several times, with deferred tool schemas going unavailable and
returning. Those notices clustered near rotation boundaries. If rotation tears down and
re-establishes MCP connections, the cost is not merely latency: tools can be *unavailable
mid-task*, which is a correctness and reliability problem, not a performance one.
*Measurable:* correlate MCP disconnect/reconnect notices against rotation timestamps.

**R3 — context continuity.** Whether the agent's usable context survives a rotation intact, or is
rebuilt/truncated. The transcripts are cumulative so the *data* is all there, but that says
nothing about what the runtime actually re-feeds the model.
*Measurable:* after a rotation, probe recall of specific early-conversation details.

**R4 — I/O.** Each rotation writes a full copy of the conversation; the newest file here is 1.9 MB
and the corpus carries 207 MB of redundancy. Likely a minor latency contributor, but it is the
component that grows quadratically.

### Sequencing note

R1 is both the most expensive suspected effect and the only one measurable from existing data.
Do it first, before any live run.

## 6. Report

Append findings to §7 of this file: file count at start and end, every session id observed with
its creation time, each permission prompt (trigger, raised, approved), each app quit with a
timestamp, roughly how many tool calls and turns the run comprised, and the verdict against §4.
State plainly if the run was too short to be informative — a weak run reported as a null result is
worse than no run.

## 7. Findings

Run 2026-07-25 02:21–02:32, session `da33c229-7c58-425c-bb55-b33b5bbebc79`.
**The ablation itself is void — see §1a.** What follows is valid anyway, because R1, R2 and the §5
cross-check are all retrospective measurements on data already on disk and do not depend on the
ablation having worked.

### 7a. Run log (§4 / §6 reporting requirements)

| item | value |
|---|---|
| file count at start (02:21) | **6** (5 baseline + this thread) |
| file count at end (02:32) | **6** — no rotation observed |
| session ids observed | `da33c229` only, created 02:21:02 |
| permission prompts | **zero** — every call was pre-authorised by the `permissions.allow` list in `settings.json` |
| app quits | **zero** |
| turn / tool-call volume | ~12 turns, ~20 tool calls, 11 minutes |

**This run produced no exposure and is not a result.** Per §4's own verdict table this is the
"no permission prompts, no rotation, short run → **inconclusive**" cell. Two of the three planned
probes were unavailable by construction: the ablation did not ablate (§1a), and manual permission
mode never engaged because the standing allow-list covers `Read`/`Write`/`PowerShell` on these
paths, so the turn-suspension substitute probe never fired even once. The live-observation arm of
this brief should be considered **not run**, not "run and came back negative."

It did not matter, because the retrospective arms settled the question.

### 7b. R1 — prompt-cache invalidation: **CONFIRMED, and directly measured**

Better than the planned latency inference: every assistant record carries
`message.usage.cache_read_input_tokens` and `cache_creation_input_tokens`, so cache behaviour is
observable exactly rather than inferred. Dataset: 5 baseline files → 1,026 distinct records
(deduped by `uuid`), 859 timestamped, **164 API requests** with measurable latency.

**The floor is 33,510 tokens** — system prompt + tool schemas, the only part that stays cached
across a rotation. Every rotation drops `cache_read` from ~270–290k to exactly that floor and
re-writes the entire conversation body:

| first request after rotation | cache_read | cache_creation | latency |
|---|---|---|---|
| 21:19:30 (→`6322c777`) | 33,510 | **109,368** | 46.7s |
| 01:27:25 (→`54204ab0`) | 33,510 | **240,710** | 57.5s |
| 01:38:36 (→`20ac496b`) | 33,510 | **261,191** | 24.1s |

(The fourth rotation, `9c02752c`, issued **zero** API requests in its 69-second life — created
01:25:03, superseded 01:26:28. A whole session id, a 1.5 MB transcript rewrite, and not one model
call.)

**Cost: 611,269 cache-creation tokens across 3 rotations — 35.5% of all 1,721,598 cache-creation
tokens this conversation spent.** Billed at the 1.25× cache-write rate. Roughly a third of the
conversation's cache-write spend bought nothing.

**The idle-expiry confound, tested and excluded.** 7 of 164 requests were cold, and only 3 were
rotations — so idle TTL expiry had to be ruled out. Cross-tabulating cold-ness against the idle gap
since the previous request produces a clean **inversion**:

| request | idle gap | outcome |
|---|---|---|
| 00:53:24 — no rotation | **7.87 min** | **WARM** (cache_read 225,942) |
| 21:19:30 — rotation | 7.23 min | **COLD** |
| 01:38:36 — rotation | 7.70 min | **COLD** |

A *longer* idle gap survived while two *shorter* ones did not, and the two that did not were both
rotations. The empirical TTL survival threshold is >7.87 min, so both of those rotations should have
been warm on idle grounds alone. Rotation invalidated them. The third rotation (01:27:25, 18.5 min
gap) is genuinely confounded — it would likely have gone cold anyway. So: **2 of 3 measurable
rotations caused a cache invalidation that idle time does not explain; 1 is confounded.**

**Latency effect — real but modest and noisy, do not overstate it.** Fitting warm turns gives
`latency = 2.12s + 0.00791·outputTokens` (≈126 tok/s, residual SD **6.47s**, n=157). Excess over
that model on the three post-rotation turns: **+20.2s, +7.3s, +4.4s** (mean **+10.7s**; z = 3.1,
1.1, 0.7). Only one of three clears 2 SD. Implied prefill throughput varies 5.4k–58.7k tok/s across
the cold turns, which is far too wide to be a real prefill rate — network and queueing noise
dominate wall-clock here.

**Verdict: the token cost is large, exact and certain; the latency cost is real but small relative
to turn-to-turn variance.** R1's framing in §5b as "the dominant cost" is right about spend and
overstated about latency.

### 7c. R2 — MCP teardown: **CONFIRMED, 6 for 6**

First, a correction to the brief's premise: **MCP connect/disconnect notices are not persisted in
transcripts at all.** Control test — my own live transcript contains zero occurrences of
"still connecting" or `mcp__`, despite my having received exactly those system reminders. They are
ephemeral context injections, never written to `.jsonl`. R2 is therefore *not* measurable the way
§5b assumed.

> Methodological note: an early scan reported zeros for everything and was **wrong**.
> `Select-String -SimpleMatch -AllMatches` leaves `.Matches` unpopulated, so every count came back 0.
> Caught by control-testing the query against a file known to contain the string. Raw-text
> `[regex]::Matches` was used instead. Worth remembering — that flag pair fails silently.

The authoritative source is instead
`…\AppData\Local\claude-cli-nodejs\Cache\<cwd-slug>\mcp-logs-<server>\`, **one file per server
connection**. For this project, 14 context-mode launches. Mapping each to its owning session id:

| MCP launch | session | relation |
|---|---|---|
| 20:57:21 | `88478329` | **session file created +0.43s** |
| 21:18:43 | `6322c777` | **session file created +0.77s** |
| 21:22:12, 21:59:10, 22:14:42, 22:20:15, 00:13:46 | `6322c777` | reconnect, no rotation (×5) |
| 01:25:02 | `9c02752c` | **session file created +1.16s** |
| 01:26:26 | `54204ab0` | **session file created +1.08s** |
| 01:38:11 | `20ac496b` | **session file created +1.21s** |
| 02:02:52, 02:14:09 | `20ac496b` | reconnect, no rotation (×2) |
| 02:21:02 | `da33c229` | **session file created +0.05s** |
| 02:29:17 | `da33c229` | reconnect, no rotation |

**Every one of the 6 session-file creations coincides with an MCP server relaunch within 1.3
seconds — 6 for 6, no exceptions.** The converse fails: 8 of 14 launches were intra-session
reconnects with no rotation.

So `rotation ⟹ MCP teardown + relaunch` holds absolutely, while `MCP relaunch ⇏ rotation`.
Reconnection is not instant — the logs record `Successfully connected (transport: stdio) in
2735ms`. **Every rotation costs a ~2.7s window in which the server's tools do not exist**, which is
the reliability problem §5b anticipated, and MCP churn is *additionally* happening ~8 more times
per session for unrelated reasons.

### 7d. Step 3 / §5 cross-check — **context-mode is REFUTED**

Grouping every `.jsonl` under `~/.claude/projects` by (project dir, first real user prompt), with a
creation-date column:

| | |
|---|---|
| files with an identifiable opening prompt | 220 |
| distinct conversations | 89 |
| multi-file conversations | 35 |
| redundant files | 131 |

**28 of the 35 multi-file conversations have *every* file predating 2026-07-21**, the earliest date
context-mode exists on disk. Not merely starting before it — finishing before it.

- earliest: **2026-06-25 12:22**, 3 files (`ps-core-pwshspc`) — 26 days before context-mode existed
- largest: **24 files, 39.7 MB**, opening 2026-06-25 22:44, entirely complete by 2026-06-28
- others across `codex-scientiae`, `ThermoMapper`, `D--aghado01` throughout late June and all of July

Per §5's own stated condition — "if any multi-file conversation predates 2026-07-21, context-mode
cannot be the cause" — the answer is 28 of them do. **Rotation is not caused by context-mode.** It
predates it by a month and occurs in projects that never loaded it. This holds regardless of §1a,
because it depends on no ablation at all.

### 7e. Structural finding — snapshots rewrite `sessionId`, preserve `uuid`

Each snapshot replays every prior record under its **original `uuid`** but stamps it with the
**new `sessionId`**. Verified: each of the 5 files contains exactly one distinct `sessionId` value,
its own. This is what makes rotation invisible to the on-disk link analysis in
[brief-redundant-session-ids.md](brief-redundant-session-ids.md) §8a — there is no back-link because
every record has been re-attributed to the new session.

It also explains R1 mechanically: if the session id appears anywhere in the prompt prefix, rewriting
it on every record guarantees a prefix change, and therefore guarantees full cache invalidation.

### 7f. Root-cause lead — the desktop app's session lifecycle (not yet confirmed)

`%APPDATA%\Claude\logs\main.log` carries session lifecycle events the transcripts do not:

```
[CCD] LocalSessions.setFocusedSession: sessionId=local_<uuid>
[WarmLifecycle:preview] Warming up session local_<uuid>
[WarmLifecycle:session] Starting idle timeout for local_<uuid>: 900s
[CCD] LocalSessions.replaceRemoteMcpServers: sessionId=local_<uuid>, serverCount=0
```

The app maintains *its own* `local_*` session handles, focuses/unfocuses them, warms them, and
**idles them out after 900 s**. A warm-up re-runs `replaceRemoteMcpServers` — which is exactly the
MCP relaunch that §7c shows accompanies every rotation, and the `.claude.json` rewrite at 02:29:17
in §1a is the same subsystem writing config back to disk.

This is a **lead, not a finding.** `main.log` uses `local_*` handles that have not yet been mapped
to CLI session uuids, and the 900 s timeout does not by itself explain the 7.2-minute and 7.7-minute
rotation intervals. It is the most promising place to look next and it is entirely local data.

### 7g. Overall assessment of runtime impact

| effect | status | magnitude |
|---|---|---|
| **R1** cache invalidation | **confirmed**, idle-confound excluded for 2 of 3 | 611k wasted cache-write tokens = 35.5% of conversation cache spend; latency +4–20s (mean +10.7s), within ~1.6 SD of noise |
| **R2** MCP teardown | **confirmed 6/6** | ~2.7s tools-absent window per rotation; plus 8 unrelated intra-session reconnects |
| **R3** context continuity | **not tested** | transcripts are cumulative and complete, but what the runtime re-feeds the model was not probed |
| **R4** I/O | **not measured** | 7.3 MB written for this conversation, 207 MB corpus-wide; grows quadratically |

**Bottom line.** Rotation degrades runtime in two confirmed, measurable ways, and the token cost is
the one that actually bites: about a third of this conversation's cache-write spend was pure
re-processing, and it scales with conversation length — worst on exactly the long threads worth
keeping. The latency penalty is real but modest and easily lost in noise. Tool availability gaps are
short but genuine. Cause is **not** context-mode; the desktop app's session lifecycle (§7f) is the
open lead.

**Inconclusive / not established, explicitly:** the live ablation (void, §1a); turn-suspension as a
trigger (no permission prompt ever fired); interrupt-correlation (untestable by design, §3); R3 and
R4 (not attempted); the actual root cause (§7f is a lead only); and 1 of the 3 rotation cache misses
remains confounded with idle expiry.
