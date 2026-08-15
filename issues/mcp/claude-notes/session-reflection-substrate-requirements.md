# What one cold session actually needed

Empirical notes from the 2026-07-25 postmortem session (`f161995e`). Not a proposal — a record of where an agent handed a corpus cold either lacked something or went wrong, and what would have prevented it.

The premise worth stating first, because it reframes everything below: **the waste and the degraded result are the same event, not a tradeoff between them.** Every correction cycle in this session was one occurrence with two costs — a confident wrong section emitted (tokens), a turn spent correcting it (attention), a rewrite (more tokens), and wrong material sitting in the artifact in between. Paying premium rates for that is the actual objection. A cheaper wrong answer would not fix it; a substrate that prevents the wrong answer fixes both halves at once.

---

## The six handoffs

### 1. The exhibit — `.discussion/opus-173b3b46…md`

Read whole across two passes, **21,961 + 20,551 = 42,512 tokens**, because it exceeded the read cap.

Reading it whole was **correct** — the three findings that carried the investigation were single lines inside 1,185, and no summary written in advance would have retained them. What was wrong was the *second* read: a blind linear continuation (`offset=642 limit=560`) against a structureless boundary.

- **Missing:** exchange-level index with sizes, for targeted re-entry.
- **Not missing:** first-pass compaction. This is a re-entry affordance.

### 2. `~/.claude/.aghado01/tools/shell-snapshots/` and `skills/context-mode/`

Both were productive. But that directory also holds `.depr`, `chat-review`, `codex-scientiae-temp`, `context-mode`, `jobs`, `session-env`, `history.jsonl`, `stats-cache.json` — and I still do not know what most of those are, because I only looked at the two that were named.

- **Missing:** any map of the directory. Every artifact in it requires a human pointer.

### 3. `reposnapshot` `tree.md` + `jso-debug.ps1` — **this one worked**

2,476 B gave me a usable understanding of ~270 KB. No pointer beyond the file itself was needed; the artifact explained its own addressing.

### 4. `jso-jackson.ps1` + `jso-hash.ps1` — **this one also worked**

89 KB file, architecture understood from a **75-line author-written header** (`CLASSES` / `FUNCTIONS` / `DESIGN CONTRACT` / `BINARY INDEX`). The `.jidx` byte format was in a comment. No search, no guessing.

Both successes share one property: **the author wrote a self-description at the top.** Nothing more sophisticated than that.

### 5. `claude-export` provenance — delivered verbally, no artifact

That `.jidx` was a performance measure for pipeline IRs, and `jso-debug` an afternoon's work atop existing primitives. Before hearing it I had asserted "`.jidx` has no portal" as a design gap and an instance of agent blindness. It was neither — it was correct for its actual consumer.

- **Missing:** provenance and intent. Nothing in the artifacts records *why* they exist.
- Worth noting: doccer's `SCHEMA.md` already defines a `provenance: { source, motivation }` field. The concept exists in the design; it just is not applied to the tools themselves.

### 6. The doccer corpus

My best process of the session — sized the file (68,918 B / 652 lines / ~17K tok), extracted headings as an index, seeked two targeted slices. Then generalized from ~115 lines into an architectural claim that was wrong.

The heading index gave me **shape but not status**. That corpus is ten discussion files across grok, gemini, perplexity, cursor, qwen, opus, plus a later `legwork/` phase. Nothing marks which conclusions survived. I read a coherent section, had no signal it had been superseded, and asserted accordingly.

- **Missing:** currency marking. Superseded vs. current.

---

## The five corrections, by root cause

| # | correction | root cause | preventable by substrate? |
|---|---|---|---|
| 1 | Finding 6 measured output tokens | wrong variable — chose what was easy to compute over what matched the mechanism | **no** — analytical error |
| 2 | "40K saved"; proposed inverting export default | did not know tool-calls/results are **opt-in additions**; frontmatter recorded settings *used*, never settings *available* or their defaults | **yes** |
| 3 | descriptive vs. prescriptive conflated | over-applied a category ("guidance failed") | **no** — analytical error |
| 4 | doccer adapter framing | read 3% of the corpus; no currency signal | **yes** |
| 5 | n=1 generalization on export structure | one Claude file + one Grok file treated as representative | **yes** |

Three of five were substrate-preventable, and all three share a root: **I could see content but not status, provenance, or defaults.** Structure alone was insufficient. An index says what exists; it does not say what is current, why it exists, or what is normal.

The specific failure mode is worth naming precisely: **coherent material with no staleness signal produces confident wrong conclusions.** That is strictly worse than missing material, because missing material produces visible uncertainty and prompts a question, while stale-but-coherent material reads as settled and gets asserted.

---

## Requirements, ranked by observed cost

1. **Coverage legibility** — "you have seen 115 of 652 lines; 3% of this corpus." Would have converted the three worst errors into stated uncertainty. This is the single highest-value item, and it is cheap: a portal that states its own extent.
2. **Currency marking** — current vs. superseded vs. exploratory. The doccer corpus is largely cross-model exploration; without status, its coherence is a trap.
3. **Defaults, not just settings** — any parameterized artifact should record the axis and its default, not only the values chosen. The exhibit's frontmatter said `exclude: [synthetic]` and I inferred a default that did not exist.
4. **Provenance / intent** — why this artifact exists and what motivated it. Already specified in doccer's schema; not applied to the tools.
5. **Targeted re-entry index** — not linear continuation. Needed on the second pass, not the first.
6. **Author-written header block** — the cheapest item here and the most effective observed. Both artifacts that needed no pointer had one.

Items 1–4 are all the same class: **metadata about the material's epistemic status**, not about its structure. That is the gap this session actually exposed. The structural work — offsets, shards, chunk IR, claims — is well developed. What was missing every time I went wrong was not *how to navigate* but *how much of this is there, is it still true, and why does it exist.*

---

## One honest limit

Corrections 1 and 3 were not preventable by any substrate. They were errors of analysis — picking a convenient metric, over-applying a category. No portal fixes those. What a portal does is stop the *other* three, which were the ones where I had least evidence and most confidence — and that inverse relationship is the thing worth designing against.
