
# what if we introduced a daemon coordinator/parent process that can mediate things like this. i gestured at this kind of concept in my old vscodepilot project ? this is a snapshot of it `D:\aghado01\project-snapshots\vscodepilot\src_20260423_121624_tree.md` and there's also various documentation in addition to the shard files in that directory. this project wasn't about para-agents, but it did have the supervisor concept in an npm implementation. might be worth some archaeology at this juncture

Good dig. Three reusable artifacts, one warning, and one find that changes para-agent regardless of what you decide about the daemon.

*(Read: tree, ARCHITECTURE, DIGEST, SALVAGE-MATRIX, majestic-garden, s006, s012. Didn't read: `job-store.ts`, `parallel-engine-v2.psm1`, the 69KB inventory doc.)*

## The find that matters most, and it's not the daemon

`safe-shell.ts` solved *para-agent's exact problem* by a different route. Its header states the motivation: native terminal tools "hang indefinitely when awaiting command output." Its answer was fire-and-forget dispatch plus reading structured JSONL, with a `ConsoleRecord` schema carrying `type`, `session`, `seq`, `cwd`, `command`, `exit_code`, `duration_ms`, `output`.

Compare that against para-agent's limitations section — marker framing, trailing whitespace unrecoverable, scrollback windows, line wrapping, no exit code for cmdlets. **Every one of those exists because I'm scraping a rendered screen.** They all disappear if the shell emits structured records instead. `exit_code` becomes a field rather than something I smuggle out through `Write-Host ('PARA'+'E...')`.

And it composes rather than competes: psmux gives persistence and the ability to drive a TUI; JSONL gives clean structured output. Load a capture module in the pane's shell profile and you get both. The pane stays the surface for humans and full-screen agents; the JSONL becomes the surface for the supervisor. Your Principle 2 already covers the seam — format-based contract, so the capture implementation stays external and swappable.

That's an upgrade to para-agent I'd take whether or not a daemon ever exists.

## What a daemon does and doesn't buy you

**Doesn't:** create a turn. That stays a harness privilege. A daemon can watch everything and still cannot wake a supervisor that isn't currently asking. No architecture below the harness fixes that.

**Does**, and these are worth it:

- **Makes the blocking-wait hybrid principled.** The harness background command becomes a thin `para-wait --until <signal>` client; the daemon owns the watching. Same wake path I sketched earlier, no longer ad hoc.
- **Survives supervisor amnesia.** This is the one nothing else solves. psmux keeps *sessions* alive; it doesn't keep *events*. When my context compacts, the conversation loses track of what was spawned and what happened. A daemon with the `job-store` ledger means a returning supervisor can ask "what finished, what failed, what's still running."
- **Cooperative cancellation.** `JobSpawnResult` carries `resultPath`, `signalPath`, `cancelPath`. That `cancelPath` is precisely the cancellation token you asked about two turns ago — the requester writes the file, the worker polls it and stops itself. No signals, no `taskkill`, no propagation, and it works across processes and machines. Strictly better than my PID-walk for anything that cooperates; keep `terminate` for things that don't. `signalPath` doubles as the wake primitive, since a file appearing is something `fs.watch` can block on.

## The garden reframes the talk-back problem

`majestic-garden.md` lands on a rule that dissolves what I called a protocol ceiling: *"producers write envelopes into the garden, consumers read from it. No source should directly inject into Copilot state."*

For an amnesiac consumer, **a durable log with a cursor beats a push notification.** A notification you weren't listening for is lost. A stream you can ask "what happened since cursor X" is not — and it survives compaction, restarts, and the supervisor simply being busy. So para-agent doesn't actually need push. It needs one normalized event stream with a cursor, where pane output, job completions, and agent state changes all land as envelopes. `read delta:true` is a crude version of this already; the garden is the principled one.

## The warning, from your own notes

> "Do not merge the old supervisor transport layer with policy supervision just because the names are similar."

para-agent sits squarely in the runtime/control-plane bucket. The name is supervisor-adjacent and will attract policy scope creep — drift detection, anti-spiral, gating. Your past self drew that line explicitly and it's worth honouring. Also flagged in the digest: `ADJUTANT_PROTOCOL` is marked broken for "relying on model compliance." My para-agent tool descriptions lean fairly hard on behavioral instruction; the distinction that survives is descriptions that *inform* versus protocols that *require obedience*.

Also noted: named pipes are your standing recommendation for cross-process on Windows, and SALVAGE-MATRIX already lists "MCP adapters" as a destination — you anticipated this layer.

## Proposed layering

```
para-agent daemon        job ledger, event stream, signal/cancel files, psmux ownership
   ↑ JSON-RPC over named pipe (or stdio)
para-agent MCP server    thin adapter — translate MCP ↔ daemon. Zero domain logic.
para-wait                thin client the harness blocks on, for the wake path
```

Which inverts what exists today: the MCP server currently *is* the logic. Moving it behind a daemon costs a refactor but is what your thin-adapter principle prescribes, and it's the only shape where a second supervisor, a CLI, and the harness can all see the same state.

Sensible order, since these are independent:

1. **JSONL console contract** — biggest quality win, no daemon required, kills most of the limitations list.
2. **Signal/cancel file protocol** — gives cooperative cancellation and the wake primitive.
3. **Daemon + ledger** — only once you actually want durable state across supervisor restarts.

I'd start at 1 and not build the daemon until 3 is genuinely felt. Want me to prototype the JSONL capture path against a psmux pane and see whether it can replace the marker framing outright?

---

# definitely want the jsonl console contract and data structures, this will require plumbing to go with. its important that interactions are facile and not spammy. I'm less concerned about governance at this stage than i am about token economy and context hygiene, especially for the supervising agent. and this means discipline with context IO without truncation or silent omissions. It means tool calls return receipts, that data structures can be parsed and tools are available to reading results selectively, finding things, querying. I think there's a place for some low level XOR bitmap kind of thing for implementing a cursor or something like that, though i might be mixing terminology there. signal/cancel file protocol are a yes, and daemon would seem to have its benefits for within-session too. pieces are still coming together

All clean. Here's where it landed.

## Built and verified — 43/43

| | |
|---|---|
| [contract/CONSOLE-CONTRACT.md](mcp/para-agent/contract/CONSOLE-CONTRACT.md) | Schema, receipt rules, cursor semantics, signal protocol |
| [src/journal.js](mcp/para-agent/src/journal.js) | Writer, cursor reader, selective body, cross-turn search, summary |
| [src/capture.js](mcp/para-agent/src/capture.js) | File-mediated capture, `.done` sentinel, cooperative cancel, self-finalizing turns |

**The fidelity problems are gone**, because output never touches the pane. Trailing whitespace survives byte-exact. A 500-char line stays one line on a 120-column pane. 5,000 lines captured with no scrollback ceiling. Unicode, shell metacharacters, and a payload literally containing `} finally {` all round-trip intact.

**Token economy, concretely:** ten turns including a 43KB body summarize to **2,557 bytes**. The journal indexing 46KB of output is itself 10KB. Bodies are fetched only when asked for, and `search` returns hit lines, never bodies.

**Two real bugs the tests caught**, both of the class you flagged:

- **`$LASTEXITCODE` leaked across turns.** A cmdlet-only command reported exit `7`, inherited from a previous `cmd /c exit 7`. Fabricated data wearing the costume of a real reading — now cleared per turn, so `null` genuinely means "no exit code."
- **Line counts off by one** from a phantom trailing-newline line, which would have silently corrupted every offset.

**One design correction:** deferred bodies no longer flip `complete`. If a referenced body counted as an omission, `complete` would be false for nearly every read containing real output and stop being worth checking. Query completeness and body deferral are now separate always-present fields.

**Discipline checks that pass:** every read reports `scanned` (so "nothing matched" is distinguishable from "we didn't look"), every `withheld` entry names the exact call that retrieves it, and a timeout leaves the turn **open** rather than closing it with a fabricated exit — then closes it correctly whenever anyone next looks.

**One prediction I got wrong:** I expected the `.done` sentinel to collapse the 0.5–0.9s detection overhead. It's ~470ms — a modest gain, not the step change I implied. The polling is genuinely cheaper (an `existsSync`, no psmux round trip), but wall-clock is dominated by dispatch and pwsh parse. The win here is fidelity and cost-per-read, not latency.

## Not done

- **The MCP surface still uses the old pane-scraping `run`.** `journal.js` and `capture.js` aren't wired into [src/index.js](mcp/para-agent/src/index.js) yet — that's the remaining plumbing, and it's where the new tools (`log`, `body`, `find`, `summary`) get exposed.
- **Interactive capture.** Only `run`/`exec` origins are captured. Commands typed directly into a pane need the profile hook, with the `Write-Host` gap documented rather than papered over.
- **Bitmap indexes** — deliberately not built. Scanning 10KB is free; revisit when it isn't.

Wiring the MCP tool surface is the natural next increment — that's what makes any of this reachable by a supervisor. Want me to take that, and should `run` switch to captured mode outright or keep the pane path available for panes without a shell?

---

# we can earn the latency win if we roll the sleeve up and apply some elbow grease. this MCP really needs to be sharp, but also observable. and i suspect there's going to be a place for different hashing methods, rolling, maybe fuzzy. i have a whole lineage of JSONL related hashing utilities, and alot of toys written in c# that could potentially be matured and vendored in here eventually. and yes to all of this RPC but we still have to account for what happens in the direct exchange channel. there's also broader workflow dynamics and flexibility therein to be considered. someone actually wrote a claude-antigravity skill and i cloned the repo. its basically the same as what i do manually with briefs as a currency , with some governance and cautionary prose in there `D:\aghado01\science-facility\skills\para-agent\SKILL.md`. i'm definitely not adapting it wholesale or even porting it directly at all, but some of this might inform my own documentation and design. and yes, mcp surface and remaining plumbing items should happen now , as well as the interactive capture hooks

All clean. Everything you asked for this turn is in and verified — **116 tests passing** (journal 48, MCP surface 53, interactive capture 15).

## Latency — the elbow grease paid

The intuitive culprits were all wrong. A trivial command took 473ms while the shell reported executing it in **5ms**. The cost was the ~450-character wrapper being *typed* into the pane: PSReadLine re-renders and re-highlights the whole input line on every keystroke, so latency scaled with wrapper length.

| Change | Saved |
|---|---|
| Wrapper moved to a file; pane types a ~60-char dot-source line | ~290ms |
| `send-keys` + `Enter` chained into one invocation (each spawn ~65ms) | ~62ms |
| cwd cached per pane, refreshed from each sentinel | ~101ms |

**473ms → 165ms median.** The benchmark also caught a bug I'd have shipped: the wait loop called `pane_dead` on *every* poll — a 58ms psmux round trip every 25ms. Now on a 2s cadence, with `fs.watch` as the detection accelerator.

The file-based wrapper turned out to be a simplification as much as an optimisation — and it fixed something I hadn't checked: `&` runs a scriptblock in a child scope, so state persistence was silently broken in captured mode. Dot-sourcing restored it, now explicitly tested.

## MCP surface

`run`/`exec` are journal-backed and return receipts. Three new tools: `log` (summary or cursor-paged records), `body` (sliced or grepped), `find` (search all turns, returns lines). `cancel` gained a `cooperative` level that writes the cancel file.

Economy, measured: **log summary = 1,218 bytes** describing five turns including a 25,905-byte body. **`find` = 483 bytes** for five hits across everything.

## Interactive capture

`ParaConsole.psm1` hooks `prompt` for metadata and slices `Start-Transcript` by byte offset for output. The transcript choice matters — an `Out-Default` proxy is the obvious approach and silently misses `Write-Host`; verified that the transcript catches it. Records go to an **inbox** that `log`/`body`/`find` drain, preserving the single-writer invariant that makes gap-free integer cursors possible. Turns dispatched by `run` are recognised and skipped, so nothing double-counts.

## From the skill — one thing worth acting on

`agy` blocks forever when stdin is an open pipe, which is why that skill needs `</dev/null` and `--dangerously-skip-permissions`. A psmux pane gives agy a **PTY**, so para-agent reaches its interactive mode: incremental output instead of ~13 minutes of buffered silence, and the option to *answer* its permission prompt rather than disabling the gate. That's the real differentiator, and it's worth writing into your own docs rather than porting theirs.

## Open

- **Hashing** — only SHA-256/8-hex identity so far. Rolling and fuzzy are unbuilt; the natural first use is elision (`sameOutputAsTurn` already does exact-match), then near-duplicate detection for repetitive agent output.
- **Daemon, direct exchange channel, workflow dynamics** — untouched this turn.
- **One decision for you:** journals default to `~/.para-agent/journals`, overridable via `PARA_JOURNAL_ROOT`. That's app-internal state I placed without asking — say if you'd rather it live under `command-center` or beside the project.

---




---

# i am also still thinking about features to include in the daemon process helping lubricate async dynamics like watching a para-agent work until it replies and then informing primary agent when its done. i alluded to this in `project-snapshots/vscodepilot` with my "supervisor" process. i think alot of that project still has material to contribute. don't forget the *_tree.md is the byte-spanned entrypoint to the shard files

Right — time to actually dig. Let me pull up the vscodepilot snapshot and mine the supervisor material through the tree entrypoint.
Not under science-facility — checking the broader D:\aghado01 layout.
Found it at `D:\aghado01\project-snapshots\vscodepilot` — twelve shards plus the tree. Locating supervisor material via the tree and a content sweep.
That's a rich vein — extracted all of it clean via the tree spans. Let me pin the salvage findings to memory, then give you the full read.
The supervisor material holds up — and your salvage matrix turns out to be the most valuable document in the pile, because it already drew the boundary your daemon design needs. Here's the read, from the tree-spanned extractions (`supervisor-host.psm1` in s006, `supervisor-bridge.ts` in s012, plus SYSTEM.md and the matrix):

**What the pattern is.** A persistent headless pwsh process runs a line-delimited JSON-RPC 2.0 loop over stdio. Two-tier dispatch inside it: fast tools (rg, fd, JSONL windows, lint) execute inline in milliseconds; heavy jobs spawn as *detached, isolated* worker processes. The spawn returns immediately with a receipt naming everything the caller will ever need: `{jobId, pid, resultPath, signalPath, cancelPath, spawnedAt, status: "running"}`. Workers write results to a JSONL, drop a `.signal` file at completion, and poll for a `_cancel.signal` — cooperative cancellation through the filesystem, no process murder required. On the TypeScript side, the bridge keeps a **promise table** (`id → {resolve, reject, timer}`) with per-request timeouts, pings for health (pid, uptime), detects crash via process-exit, auto-restarts with a capped retry count, and — the detail worth stealing verbatim — **rejects every pending request on shutdown**, so no future is ever silently orphaned. That's your "futures never rot" discipline, already implemented.

**The key adaptation for para-agent:** the vscodepilot design needed separate signal files because it had no durable ledger. Para-agent *has* one — the acceptance WAL. The terminal marker row **is** the completion signal, already durable, already crash-reconciled. So the daemon's watcher shouldn't invent signal files; it should **tail the `.acceptance.jsonl` for terminal markers** and notify the primary when one lands for a watched exchange_id. The whole "watch a para-agent until it replies, then inform primary" feature reduces to: WAL tailer + notification channel + the promise-table bookkeeping from the bridge. Your storage layer already did the hard part.

**The boundary your own matrix insists on, and it's load-bearing here:** "This is execution orchestration, not supervision in the policy sense — do not merge the old supervisor transport layer with policy supervision just because the names are similar." Generalized to para-agent: **daemon observations are transport facts, never mediated evidence.** The daemon may notice a pane process exited or went silent and *inform* the praetor — prompting a join, a status check, maybe a cancellation — but it must never *terminalize* an exchange, because the contract already rules that process silence and screen stability aren't terminal proof. Daemon signals prompt joins; only correlated native terminal events, through the assembler, constitute completion. That keeps your three planes clean: runtime/control (daemon, lifecycle, liveness), evidence (contract, store), policy (praetor skill, profiles, arbitration). The matrix's classification rules — "owns signal files, process handles, RPC, retries → runtime plane" — port to para-agent's package layout essentially verbatim.

**Still mineable from the snapshot** for later passes: `job-store.ts` (the jobs.jsonl persistence and polling logic — the part the WAL replaces, but its status-tracking API shape may still inform the daemon's query surface), `parallel-engine-v2.psm1` for worker internals, and the context-ingress/"garden" bucket, which is empty of implementation but carries your transport doctrine — named pipes for cross-process, concurrent queues in-process, memory-mapped files only when payload size warrants — which is exactly the decision you'll face for the daemon→primary notification channel. All of this, including the WAL-as-signal insight and the plane boundary, is now in the praetor memory file so the codification session starts warm.