
# what about a tool that instead of making you emit the content to the tool call, you instead have a tool that you point to the content in the history and that gets written somehow. and what about pretoolcall and posttoolcall hooks? despite everything that went wrong with context mode, some things it did do well with my custom hooks helping out, which mainly was in teh pre- and post-tool hooks. i dont want to reimplement context-mode wholesale, but perhaps exctract my own custom hooks and handling based on the parts that i know worked well without the baggage of context-modes own architectural flaws

Two proposals, and they have very different prospects. Let me take the pointer idea first because it has one specific limit that decides whether it's worth building.

## Pointing at content in history

Mechanically it works. A `PreToolUse` hook receives `session_id`, and the transcript path is derivable from that plus cwd — so a hook can read the JSONL itself, resolve a reference like `write_from(marker: "journal-v1", path: ...)`, write the file, and return a receipt. No harness change needed. The server side can't do it (an MCP server sees only its own arguments, never the conversation), but a hook can.

The problem is upstream of the mechanism: **the content has to be in history for the tool to point at it, which means I already emitted it.** For original authorship — 159 KB of Writes this session, nearly all files I authored rather than copied — there is nothing to point at until after I've paid.

So it helps in exactly two cases:

- **Rewrites.** `framing.js` was written twice; the second 11 KB was redundant. Real, but this session's repeat-write population is maybe 20 KB of 159 KB.
- **Copy/move/derive.** Content already in context from a read, written elsewhere.

And that second case is already better served by `Edit`, which transports only the delta. Which is the awkward conclusion: **where pointing at history helps, Edit helps more; where Edit can't help — original long-form generation — pointing at history structurally can't either.** I'd measure the repeat-write share before building it.

The variant that *does* attack original generation is making the argument a **transform rather than content**: "produce this file by applying these operations to that one," or "render this template with these values." The bytes that cross are the instruction, not the artifact. That's the computational escape valve from the thread, and it's the only shape that reduces first-copy cost without a second agent.

## Hooks — sound, and here's the honest boundary

Your instinct to extract rather than reimplement is right, and your own postmortem already did the hard part. None of context-mode's six failures were in the hook taxonomy:

1. conversation identity guessed from PID / "latest session"
2. data plane became control plane (repair, upgrade, deploy beside execution)
3. hooks became lifecycle *mutation* points — SessionStart healing plugin caches
4. "client agnostic" as shared implementation rather than shared contract
5. enforcement, telemetry, and continuity mixed in one path
6. the hygiene machinery generating context of its own

The taxonomy survives all six. The rule that falls out — *hooks are thin edge adapters, not business-logic containers* — is the whole extraction discipline. A hook decides **where execution belongs** and records **what happened**. It does not parse, persist, summarize, or repair.

**What hooks can genuinely do here:**

`PreToolUse` supports `permissionDecision` *and* `updatedInput` — it can rewrite a tool's input before execution. But `updatedInput` changes what the **tool** receives, not what the **transcript** recorded; the assistant message carrying the 14 KB already exists. So hooks cannot un-emit. They redirect future behavior; they don't reclaim past bytes.

`PreCompact` is the one place already-emitted bulk might actually be dropped, and superseded write arguments are the ideal candidate — the file is on disk, so the bytes are recoverable by definition. Whether this harness lets a hook *drop* rather than only *inject* I still don't know, and it's the single highest-leverage unknown in this whole thread.

**The one I'd build first**, because it's cheap and unblocks the rest: a `PostToolUse` hook logging `(tool, path, bytes, hash, superseded_by)` to JSONL. That's your pollution meter — the thing you currently detect by feel, made numeric per session with no archaeology. It costs nothing, risks nothing, mixes no planes, and it answers the questions that decide everything else: what share of Write bytes are rewrites, how many variants per file accumulate before a turn ends, whether edit consolidation alone recovers most of it.

It also gives the extraction a natural first member — pure telemetry, fail-open, zero authority — which is the right shape to establish before any hook gets enforcement power. Point me at the context-mode hooks you want salvaged and I'll pull the taxonomy out without the baggage.

---

# ok, so i'm inclined to do some cherry picking from context-mode, but we need to understand how hooks iteract with the broader context-mode architecture in order to surgically extract the mechanism we want. This is the hooks setup for the claude code client that is based on the original custom hooks `C:\Users\azrie\.claude\.aghado01\context-mode-settings.json`, but which was recast as part of the custom, no defunct, context-mode-core `D:\aghado01\pet-projects\context-mode-core`, there was also the nudges from the MCP that probably played a role

Now the picture is complete, and the key finding is better than expected.

## Your custom routing is already architecturally separable

The call path is:

```
hook entry → hook-runner (thin) → native-runner
   1. normalizeNativeHookInput      PowerShell/Cmd → canonical "Bash"
   2. customRoutingDecision  ←── YOUR LOGIC. In-process. Short-circuits on hit.
   3. spawnSync → upstream context-mode package hook   ← only if yours returns null
   4. advisoryRoutingResponse       deny → context downgrade
   5. guardClaudeShellRewrite       harness-version workaround
   6. appendInfrastructureContext   SessionStart injection
   7. directMcpResponse             tool-name prefix rewriting
```

**Your routing runs first, in-process, and returns immediately when it fires — it never touches the upstream package.** So the thing you want to keep was already on a fast path that bypassed everything that went wrong. That's why it worked.

Its total coupling to the architecture is **five config scalars**: `routingMode`, `sandboxShellFamily`, `storageRoot`, `jsoJacksonRoot`, and `toolNaming`. Everything else — the client registry, infrastructure hydration, adapter dispatch, deploy/patch machinery — is what it was *embedded in*, not what it *depends on*.

## What actually worked, specifically

- **`isPotentiallyLargeShellCommand`** — per-shell-family regexes over the command text. Predicts output volume from *syntax* rather than filetype, which is the good instinct.
- **`structuredFileDecision`** — and note its best feature: `if (toolInput?.offset != null || toolInput?.limit != null) return null`. **A bounded read passes unchallenged.** That's the "inspection barrier, not a ceiling" principle already implemented, two years before the Codex thread articulated it.
- **The `.md → context` vs `.jsonl → deny` split** — you already distinguished evidence from exhaust. Markdown got advice; JSONL got denial. The nuance you told Sol was missing is partially there; what's absolute is the *threshold*, not the *policy*.
- **`markGuidanceOnce`** — atomic `openSync(marker, "wx")`, one nudge per session per key. Twelve lines, and it's the direct antidote to "hygiene machinery generating context of its own."
- **The advisory downgrade with a security carve-out** — `/security policy|blocked by security/` denials stay authoritative while token-routing denials become nudges. That's enforcement and advice already separated, which is postmortem failure #5 solved in place.
- **The decision rank** — `deny(4) > ask(3) > modify(2) > context(1)` with `combineDecisions` taking the max. Clean composition, platform-neutral, wire formatting kept separate.

## Three landmines to drop on the way out

**`sessionIdFromInput` falls back to `pid-${process.ppid}`** (custom-routing.mjs:141). That is precisely the load-bearing error your own postmortem identified — process identity masquerading as conversation identity. In the extraction, delete the fallback: no `session_id` means identity is *unknown*, which is a valid state. Nudge-once degrades gracefully to nudge-per-process, which is acceptable; a wrong session id is not.

**Process spawn per hook call.** `spawnSync(process.execPath, [hookPath(...)])` boots a full Node process on every matched tool call, and your PostToolUse matcher covers ~20 tool names. That's the "subprocess-per-hook overhead" the postmortem cited. Extraction eliminates it entirely — everything you're keeping runs in-process.

**`updatedInput` is not trustworthy for shell tools** — and this corrects what I told you two turns ago. `guardClaudeShellRewrite` exists because *"Claude Code 2.1.x can ignore updatedInput.command for shell tools"*, so a rewrite would silently let the **original** command run. That's the worst failure shape available: you believe you redirected, and you didn't. If you plan to lean on `updatedInput`, re-test it against current Claude Code first. The safe pattern is the one that code fell back to — deny with the replacement command in the reason.

## What was never there

**PreToolUse never matched `Write` or `Edit`** — the matcher is `PowerShell|Bash|Cmd|Read|Grep|Glob|WebFetch|Agent|mcp__`. Context-mode was a purely *inbound* system. The write-through pollution that's bothering you now was never in scope, so there's nothing to extract for it. That's new work, and the PostToolUse telemetry is its natural first step — `Write|Edit` are already in the PostToolUse matcher, so the wiring exists.

## Proposed shape

One file, no dependencies, ~250 lines: decision vocabulary + rank, `canonicalToolName` trimmed to this harness, the shell detectors, `structuredFileDecision` with `statFile` injected (already testable as written), `markGuidanceOnce`, the advisory downgrade with its security carve-out, and a Claude-only wire formatter. Config becomes four constants at the top instead of a client registry.

Two changes I'd make rather than port verbatim: default `routingMode` to `advisory` so every routing decision is a nudge — that matches what you've said about arbitrary denial — and add the PostToolUse write meter, since it's the measurement that tells you whether the thresholds should become relational.

Want me to build that extraction? I'd put it in `science-facility` rather than resurrecting anything under the old paths, and I'd keep the postmortem's six failure modes as an explicit "do not re-add" list in the file header so the boundary stays visible to whoever touches it next.

---

# well i think we need to unpack some related elements like the implementation details of handling different types of hooks and scenarios. i like RPC-style here and the idea of virtual databases, artifacts get emitted with full information but potentially parsed into data structures that can be selectively read , with routing guidance etc to protect the context window but while not blinding the agent or using blunt-force policies like arbitrary threshold for compaction or truncation. part of context mode's architecture that it did well conceptually was offloading to sqllite and making that queryable, but its crude implementation based on BM25 for example was weak. and i'm not reaching for context-mode's memory system or transcript ledgers, im just speaking to a principled approach for handling heterogeous tool calls and file reads etc so that the agent always has the ability to see what it needs but has the opportunity to reason about what it gulps before it does so. an di'm not even saying it needs to all happen now -- most immediatley i want to try to address the write-through problem if possible -- but its worth bringing up at this juncture. and i'm also not married to sqllite-- i could use jsonl data structures with primitives i've already built elsewhere or am currently building elsewhere to provide plumbing for appending/reading/querying/what-have-you against ephemeral mcp artifacts to serve the cause

My anchor-patch hypothesis was wrong, and the data says something more interesting.

```
EDIT payload, 74 edits:
  old_string (re-quotes disk content)   25.3KB   26.3%
  new_string (genuinely new)            71.1KB   73.7%
```

So an anchor-based patch tool that eliminates `old_string` saves 25.3 KB of 269.6 KB — **9.4%**. Real, but not the lever I thought.

## What the data actually says

**The pattern is write-then-iterate, and it amplifies.**

| file | writes | edits | edit payload |
|---|---:|---:|---:|
| index.js | 1 | 18 | 25.5 KB |
| capture.js | 1 | 11 | 14.9 KB |
| journal.js | 1 | 11 | 10.3 KB |
| framing.js | **2** | 6 | 9.5 KB |

`index.js` cost ~14 KB to write and ~25 KB to refine — **~40 KB of context for a ~20 KB file.** Across the write path: 269.6 KB emitted to produce roughly 110 KB of final files. **~2.45× amplification.**

Two numbers matter most:

- **95.6 KB of edit payload targets files written in this same session** — every byte of it superseded by the file's current on-disk state.
- **15.8 KB of redundant rewrites** (`framing.js`, `smoke.mjs` written twice).

That's **~111 KB — 41% of the entire write path — provably dead**, recoverable by reading the current file. And **44 of 74 edits were consecutive edits to the same file** (18 runs), i.e. foldable into the preceding call.

## The levers, ranked by what the measurement supports

**1. Delegation — attacks the multiplier, not the first copy.** I'd been arguing this as "saves the 14 KB write." It's better than that: if agy writes *and iterates*, the whole 2.45× stays in agy's context. `index.js` becomes ~1 KB of brief plus receipts instead of ~40 KB. The amplification factor is the argument for delegation, and it's the thing no local tool can recover.

**2. Transcript trim — 41% provably superseded.** This is now well-evidenced rather than speculative. Superseded edits and redundant rewrites are exactly identifiable (file written or edited later in the same session), and the current file on disk is the ground truth they're superseded by. Works retroactively on every session you already have.

**3. Edit folding — free, behavioral, mine to fix.** 44 foldable edits. Half of them were me touching the same file repeatedly within one turn when a single consolidated edit would have done. No tooling required; I should just stop doing it.

**4. Anchor patching — 9.4%.** Worth having eventually, not worth building alone.

## On the conceptual frame

The sharp version of why BM25 was weak isn't that the implementation was crude — it's that **ranked retrieval is the wrong primitive.** BM25 answers "which chunks score highest for these terms." What this job needs is "give me exactly this span." Ranking *guesses* what you want and — the part that matters for your "don't blind the agent" constraint — it returns top-k with no map, so the agent cannot see what it *didn't* get. A structural index inverts that: outline and sizes first, exact bytes second, and the omissions are addressable.

Which means **SQLite vs JSONL is the wrong axis.** You could keep SQLite and be fine if the primitive were `address(selector) → exact bytes` instead of `rank(query) → chunks`. The failure was the access shape, not the store. And your jso-jackson primitives — byte-offset indexes, record windows, previews, canonical hashes — are already the right shape. That's the same convergence the Codex thread flagged: you keep rebuilding this substrate (reposnapshot, cybernetic-codepilot, mdnav) because it's the correct one.

para-agent's journal is that pattern applied to one artifact class. Generalizing it is `(identity, structure index, selective accessors, exposure ledger)` per class — console runs, documents, code, JSONL — over whatever store. Not now, but that's the shape.

## For "most immediately"

I'd build the **trim tool** first. It's the only option with a measured 41% target, it works on your existing corpus, and it doubles as the instrument — it reports amplification per session, which is how you'd know whether delegation is earning its complexity once `para_write` exists.

Two things I'd want settled before writing it: whether resume-from-edited-transcript actually works here (ten-minute test on a throwaway session — if it fails, the tool is export-only and delegation becomes the sole live remedy), and whether you want it to elide superseded edits only, or also collapse multi-write files to their final version.

And I'll fold edits from here on regardless — that one costs nothing and it's 44 calls this session alone.

---

# well i would point out that what we're discussing now is something bigger than the para-agent MCP. certainly relevant to it, but i want to implement some custom MCP capabilities for helping me with token waste and context pollution based on these ideas with claude and other agents in isolation, para-agent would inherit this kind of thing perhaps directly as part of a family of MCPs being built from the ground up. and regarding sql-lite vs jsonl, i prefer jsonl because i have so many primitives built. and there's actually some really good work happening in codex-scientiae with the jsonl-v2 work, which isn't deployed but is being developed as a renewed set of jsonl/json primitives for that project that are probably going to at leastp artially be transferable to be merged with jso-jackson's successor and serve projects like this. i was also just discussing some concepts behind simdjson and how those are relevant to doccer regarding XOR-based primitive operations that are useful and transferrable without the SIMD or the package

Scope correction taken — and it changes one thing materially.

**If a family is coming, the address model has to be settled before member two.** para-agent is already member one, and it already diverged: its journal invented `turn`/`seq` as identity, which is doing the work of `artifact_id + version + selector` — three roles the Codex thread specifically says one identifier can't carry. Right now that's harmless because nothing else reads it. The moment a second MCP has its own notion of identity and freshness, you get exactly the fragmentation the thread warned about — *"neither needs to invent its own notion of freshness or context residency"* — and reconciling two live address spaces later is far more expensive than agreeing one now. It's cheap today: a shared envelope and a reference grammar, no implementation commitment.

That also reframes what the members are. Console/execution artifacts (para-agent), document navigation (mdnav), write-with-receipts, transcript hygiene, JSONL/data — these aren't five tools, they're five *structural index providers* over one address model, each with its own selector vocabulary. Which is precisely why the substrate question is the interesting one and not the storage engine.

## On simdjson's XOR primitives — they transfer, and they matter more than as an optimization

The one worth lifting is **prefix-XOR over quote positions**. Given a mask of unescaped `"`, a running parity toggle gives you, in one pass, which bytes are *inside* a string. No lookahead, no parsing, O(n). SIMD makes it fast; the parity scan itself is a single bit of state and works scalar.

The subtle half is escape handling — a `\` escapes the next byte, but runs matter: odd-length backslash runs escape, even-length ones don't. That's a tiny state machine, and getting it wrong is the classic silent JSON-scanner bug.

Why this is load-bearing rather than a micro-optimization, given everything above: **the structural index is what every anchor resolves through.** If boundary detection is wrong, every byte span is wrong, and it fails *silently* — you get plausible content from the wrong place. Two concrete instances already in your stack:

- **JSONL record splitting.** Naive `split('\n')` is incorrect whenever a string value contains an escaped newline. Prefix-XOR gives correct record boundaries without parsing any record. That's directly a jso-jackson/jsonl-v2 primitive, and it's the difference between a byte-offset index you can trust and one that's usually right.
- **Markdown fences.** mdnav already handles this specially — its README notes a naive `grep '^# '` found 38 H1s in a transcript that has 22, because of fenced content. Parity-scan is the general form of that fix, and the same primitive covers fences, quotes, and comment regions.

There's also a structural echo worth naming: simdjson's **two-stage design** — stage 1 builds a positions-only structural index, stage 2 parses on demand — is the same shape as mdnav (outline first, materialize spans second) and the same shape as the artifact plane (receipt first, body on request). Byte level, document level, corpus level, one pattern. That's a good sign the architecture is right rather than invented.

I don't have context on **doccer** — you haven't pointed me at it and I'd rather ask than guess what it does.

## Next step

Three candidates, and I'd order them:

1. **Settle the address model** — half a page: reference grammar, envelope shape, what a selector is per class, what a receipt must state. Cheap now, expensive after member two. It's also the thing that makes para-agent's journal retrofittable rather than a fork.
2. **Survey `codex-scientiae` jsonl-v2** — if it's becoming the substrate, its primitives should inform the selector vocabulary rather than the other way round. Worth doing before, not after, the address model if you think it's far enough along to constrain the design.
3. **Trim tool** — still the best-measured immediate win (41% provably superseded), and independent of the above.

If jsonl-v2 is substantially formed, I'd do 2 → 1 → 3. If it's early, 1 → 3 and let jsonl-v2 land against a settled address model instead of shaping it. Which is it?

---

# the "two-stage design" principle resonates. doccer also has "stage design" principles. i was just digesting a bunch of planning materials for upcoming doccer development `D:/aghado01/codex-scientiae/issues/doccer/discussions/sol-doccer-material-basis-and-public-composability-20260806_105530.md` and doccer itself lives under `D:\aghado01\codex-scientiae\src\doccer`.

This is more rigorous than anything else in the lineage, and it corrects two things I was loose about.

## The staging principle — doccer's is stronger than simdjson's

simdjson is two-stage: index everything, then parse on demand. Doccer isn't staged at all in that sense — it's a **rung ladder where cost scales with what you touch**:

> Every rung is usable without the rungs above it... "Full doccer" — sweep → collect → validate → laminarize → tiered acceptance — is one composition of these primitives, never the entry price.

And `TextMaster` computes fingerprint and topology *on first use*. That's the difference that matters for our MCP family: two-stage still implies you run stage 1 over the whole artifact before any access. The rung model says a small job pays for the spans it touches and nothing else. For an artifact plane where most artifacts are never read at all, that's the correct shape — full indexing on capture would be the same "eager materialization" mistake one level down.

The XOR section states the same thing for the scan: `classify → derive valid toggle events → prefix parity → consume or harvest`, **"with each arrow independently usable. It is not `prefix XOR = parser`."**

## Two corrections to what I told you

**I lumped escape handling into prefix parity.** I called odd-backslash-run detection "a tiny state machine" as if it were part of the same primitive. Doccer separates it correctly as the *fifth* operation, above the raw four, with its own run carry — "not reducible to pointwise XOR alone." That separation is the whole point of the layering table, and collapsing it is exactly the conflation the document is written to prevent.

**I overstated prefix parity as a general region primitive.** For JSONL record boundaries and Markdown fences the toggles are non-overlapping, so it works — but the document is explicit that for arbitrary overlapping intervals it computes **odd-coverage parity, not union coverage**, and "must therefore not be presented as a replacement for `SpanSet` normalization." My pitch was right for the two cases I named and wrong as stated generally.

Also worth flagging for jsonl-v2 specifically: *"XOR must not be reused as a fingerprint or equality proof merely because it is fast. Cancellation makes an XOR fold a poor identity commitment."* That's the tempting wrong turn when you have fast XOR primitives and need content identity.

## The actual payoff — the address model is already solved

Two turns ago I said settle the address model before MCP member two. That recommendation now changes from **design it** to **lift doccer's**, because H0005 has already done the hard part:

> **compatibility fields** — addressed-unit sequence, address unit, logical length, boundary contract, document/revision identity, canonical material commitment
> **storage/execution fields** — backing encoding, indexes, caches, vector tier
> **lineage/evidence fields** — retained source assets, transform identity, coordinate maps, loss records

That is precisely the discrimination an artifact reference needs, and the failure it prevents is one I'd have walked into: treating "same content" as "same coordinate space." A byte-addressed UTF-8 master and a UTF-16 master **cannot** be coordinate-compatible even when their scalar content agrees. para-agent's journal currently has one identity (`turn`) doing all three jobs — it doesn't matter yet because there's one producer, and it would matter enormously the moment a document provider and a console provider both claim to address "the same" artifact.

The other line worth stealing verbatim is the doctrine:

> Claims carry evidence. Queries execute named policies and return results. Orchestration selects policies and interprets results. The representation never pre-resolves.

Applied to context hygiene, that *is* the inspection barrier — but stated as an architectural law rather than a preference. The routing layer returns facts (size, structure, overlap, prior exposure) plus named policies; it never selects. And the admission test — *"deterministic; eliminates repeated mechanical work; preserves literal source material; decides nothing about meaning"* — is a sharper gate than anything I proposed, and it's exactly what would have caught context-mode's data-plane/control-plane merge and its self-generating context.

## Where that leaves sequencing

Doccer isn't dependable yet — pre-graduation, and the D41 vector lane has "no vector type, classifier surface, harvest API, or accelerated backend implemented." So the MCP family can't sit on it today. But it has a deliberately domain-agnostic CLI at task granularity, which means the family could eventually adapt over a *verified* span algebra rather than a hand-rolled one — and designing toward that costs nothing now beyond adopting the vocabulary.

So I'd revise my earlier ordering: not "settle the address model," but **transcribe doccer's compatibility/storage/lineage split into the MCP reference grammar** — a much smaller job, and it keeps the two from diverging while doccer is still moving. Then the trim tool, which is independent of all of it.

One thing I'd want before writing any of that down: whether jsonl-v2 is already carrying its own identity/compatibility notions, since that's the third party to this and the one I haven't seen.

---

# jsonl-v2 isn't an extension of doccer, its a set of reusable utilities for creating jsonl artifacts, life cycle, and other things, more about logistics D:\aghado01\codex-scientiae\src\shared\jsonl-v2.ps1 and D:\aghado01\codex-scientiae\src\shared\jsonl-store-v2.ps1 .. which might smell like use-case specific but i hope the abstract concepts are apparent enough

Not use-case specific at all — both headers disclaim application concerns explicitly, and the one specialization (`New-JsonlInventoryStorePolicy`) is twenty lines binding parameters of the general policy. The abstract concepts are very apparent, and more than that: **they close a loop.**

## Four independent systems, one address shape

| | address | drift guard |
|---|---|---|
| **doccer** | master identity + `(start, end)` + compatibility fields | fingerprint over code units, lazy topology |
| **mdnav** | `Dnnn:Hnnnn@digest` → half-open byte span | source hash + heading digest |
| **jsonl-v2** | `(RecordIndex, ByteOffset)` + `.jidx` | `sourceLength` + `lastWriteUtcTicks` |
| **para-agent** | `turn`/`seq` + `ref` | `out_hash` |

Every one is *ordinal + byte address + a guard that fails loudly on drift*. And three of the four explicitly separate the cheap guard from provenance-grade identity — jsonl-v2 says it outright: *"This is not a content hash; applications requiring provenance-grade verification should layer that policy above these primitives."* That's doccer's compatibility-vs-lineage split, stated independently, in PowerShell, about a different substrate.

So the address model I said should be settled has been designed four times already. The family's job is to *name* the convergence, not invent a fifth.

Three more convergences, all unprompted:

- **Receipts.** `New-JsonlStoreMutationResult` returns `{Path, Operation, Changed, AffectedRecords, RecordCount, Bytes, IndexPath, IndexStatus, StoreKind}` — counts and status, no payload. That is structurally identical to para-agent's `run` receipt. Same object, arrived at from opposite directions.
- **Policy passed per call, never chosen by the library.** *"A policy is deliberately passed by the caller on each policy-aware operation."* That's doccer's doctrine verbatim, and it's the same rule as "the routing layer returns facts and named policies; it never selects."
- **Scope statements with "deliberately absent" lists.** doccer has one, jsonl-v2 has one, jsonl-store has one. That's the governance mechanism that keeps a kernel from silently becoming a pipeline — precisely what context-mode lacked when its data plane grew a control plane.

One detail I'd single out as a design instinct worth stealing: *"SchemaPath requires SchemaValidator; schema validation must not be implied but skipped."* Refusing a configuration that would be silently inert. That's the same species as doccer's residual doctrine and as the receipts' `complete` flag — never let absence of enforcement look like enforcement.

## What para-agent should take immediately

**The writer lease.** I built `ingestInbox` with rename-to-claim and wrote in the margin *"small race window. Acceptable for v1 with a note."* jsonl-v2 solves it properly: a named cross-process mutex derived from SHA-256 of the canonicalized path, a `FileShare.Read` writer lease, and — the part I wouldn't have thought of — **readers that refuse rather than return torn data** (*"Cannot obtain a stable JSONL view while a writer holds the store"*). My PowerShell producer has a 5×10ms retry loop; that's a mitigation, not a solution. This is a direct upgrade.

**The `.jidx` sidecar.** `Journal._readAll()` parses the entire file on every read — I noted an offset index as "the scaling path" and left it. JSOI v2 is that index, already specified, with a staleness guard. `Get-JsonlRecord` by ordinal is exactly what a `seq` cursor wants.

## What none of them has

doccer tracks *basis*. mdnav tracks *reads* (`reads.jsonl`). jsonl-v2 tracks *index staleness*. **None tracks what the model has been shown.** The exposure ledger is the one genuinely new plane, and it's the thing the Codex thread named as the missing abstraction. That's the family's actual contribution — everything else is assembly of primitives you already own.

## Revised sequencing

1. **Write down the convergence** — one page: the address triple, the guard-vs-identity split, the receipt shape, policy-per-call, the admission test. Not a design, a transcription of what four systems already agree on. Cheap, and it's what keeps member two from diverging.
2. **Retrofit para-agent's journal** onto the lease + `.jidx` pattern. Small, fixes a known race, and makes the journal a conforming member rather than a one-off.
3. **Trim tool** — still independent of all of it, still the best-measured immediate win.

The exposure ledger comes after, because it's the only piece with no prior art to lift and it should be designed against a settled address model rather than alongside one.

---

# well if jsonl-v2 doesn't have it yet, it is planned to expose a generic "ledger" object that would probably be able to serve the ledger function you are pointing to

That changes the sequencing usefully — exposure stops being the one piece with no prior art, and becomes a policy kind over a substrate you're already building.

It also clarifies a distinction worth naming: **there are two ledgers, not one.** para-agent's `journal.jsonl` is a *production* ledger — what happened. mdnav has the same split (the index is production, `reads.jsonl` is delivery). Exposure is a *delivery* ledger — what was shown to a model. Same format, same primitives, different kind. Every artifact provider gets a production ledger; the context runtime gets one delivery ledger spanning all of them.

If the generic ledger is still being shaped, five things exposure would ask of it:

**1. Append-only must be a kind, not a convention.** `Sort-JsonlStore` and `Remove-JsonlStoreRecords` exist in the store layer, and `RecordIndex` is positional. A canonical sort over a ledger silently invalidates every reference that addressed an entry by ordinal — and it would look like maintenance, not corruption. Either the ledger kind refuses those operations outright, or entries carry an immutable id independent of position. Given jsonl-store already validates policies aggressively and refuses ambiguous combinations, this fits its existing style: a `Kind = 'ledger'` whose mutation surface is append.

**2. Epoch as a first-class field.** Residency resets at compaction, so almost every useful query is scoped to an epoch. That makes it a partition key rather than an ordinary column.

**3. It records delivery, never residency.** This is the discipline that matters most, and it's the same three-state shape as doccer's residual: an entry saying "delivered at epoch 7" does not entitle anyone to conclude "resident at epoch 8." The thread put it plainly — *"previously delivered does not mean still remembered."* If the schema lets a consumer read residency directly off a delivery record, the ledger becomes a source of confident wrong answers, which is worse than having none. Residency should be a derived judgment that can return *unknown*.

**4. Aggregation belongs above the ledger.** The question exposure actually gets asked is "how much of this artifact has been shown," and answering it requires merging overlapping selectors — a subtree read subsumes its units rather than double-counting, which is what mdnav's coverage already does. That's interval algebra, which is doccer's job, not a ledger query. Keeping it out preserves the ledger's "records facts, decides nothing" posture and avoids a second implementation of union/cover.

**5. Selective query must not require loading the ledger.** It grows with every materialization, so `(epoch, artifact)` lookups need to go through the index rather than a scan. `.jidx` plus `Find-JsonlRecord` already covers this — worth confirming the ledger kind inherits it rather than being a bare append target.

The nice consequence: if that lands, para-agent's journal becomes a conforming production ledger and the exposure ledger is a sibling of the same kind, rather than something I hand-roll a fifth time in Node. Which argues for doing the retrofit *after* the ledger object exists rather than before — no point porting the journal onto `.jidx` by hand if the generic thing is arriving with it.

So: trim tool first (independent of all of it), transcription of the convergence second (it's cheap and it informs the ledger schema while that's still soft), and the journal retrofit waits for the ledger object. Does that match where you'd put it?
