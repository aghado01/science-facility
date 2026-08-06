I'll start by mapping out the doc-dive skill directory and finding the mdnav tooling, then read both docs.

Both docs read. Now the mdnav tooling — README first, then the implementation.

Now the implementation. Let me check sizes and the wrappers first.

Now the acceptance tests and the two thin wrappers.

The hygiene guard works as designed (that's a good sign — it refused a work dir inside the corpus). Retrying with a sibling work dir:

One more quick confirmation of a second inconsistency I spotted in the code (profile's `break` construct vs the `--by breaks` basis), then I'll write up the review:

Review done — tests pass (130/0), I read both docs end-to-end, the full implementation, the README, and dogfooded mdnav on the drafts themselves. Here's the full picture.

# TL;DR

The tooling is in genuinely good shape — one real correctness bug (noise detection is fence-blind, so `--strip all` corrupts code examples), one profile↔basis inconsistency, and some doc drift. The two skill docs aren't actually in conflict so much as in a **supersession relationship the notes only partially declare**: `skill-draft-notes.md` corrects the DRAFT where it says so (§1), but I found four tensions neither doc resolves — most importantly, the per-run read ledger can't support the multi-session invariants the notes demand of it.

---

# mdnav tooling

**Strengths first, briefly:** the partition invariant is the right load-bearing test and it holds; the address model (anchor = span = re-readable batch) is clean; the artifact hygiene guard works — it refused two of my own careless work-dir placements during this review, which is the best kind of test. The test suite is unusually honest (it encodes the real-dive blockquote bug as a regression test).

**F1 — noise detection is fence-blind (confirmed, the one real bug).** [mdnav.mjs:223](skills-dev/doc-dive/mdnav/mdnav.mjs:223) `noiseSpans` scans lines with no fence tracking, while the heading scanner is scrupulously fence-aware. Repro: a doc with an ` ```html ` example block — `--strip all` emptied the fence to blank lines and dropped a literal `<br>` from prose, all silently (sub-1KiB elisions leave no placeholder). Same root cause makes `index`/`discover` triage report a doc as "25.7% embedded data or HTML markup" when every byte of it is quoted example code. For a tool whose covenant is byte fidelity, this is the gap to close: skip noise spans that fall inside fence runs (the fence state machine already exists in `constructRuns` and `analyze`). Design-discussion corpora — your primary corpus type — are full of fenced HTML/markdown examples, so this will fire in practice.

**F2 — `profile` and `--by breaks` disagree on what a break is (confirmed).** The construct scanner accepts `-{3,}|*{3,}|_{3,}` ([mdnav.mjs:277](skills-dev/doc-dive/mdnav/mdnav.mjs:277)); the segment basis accepts only exactly `---` ([mdnav.mjs:416](skills-dev/doc-dive/mdnav/mdnav.mjs:416)). Repro: a doc delimited by `***` and `----` profiles as 20% `break`, but `--by breaks` returns one segment covering the whole file, no warning. The profile→marks→basis bridge is the documented telescope path, and it dead-ends here. Widen `analyze()`'s break detection to match (keeping the blank-line guard against setext).

**F3 — help/README drift.** [mdnav.mjs:1153](skills-dev/doc-dive/mdnav/mdnav.mjs:1153) says `'all' = data-uri + html` but `STRIP_ALL` includes `signed-url`; the usage line at 1131 omits `signed-url` from the kinds list. Also [README.md:365](skills-dev/doc-dive/mdnav/README.md:365) has a broken code fence (closing ``` glued to the following sentence). And the comment at [mdnav.mjs:222](skills-dev/doc-dive/mdnav/mdnav.mjs:222) claims multi-line HTML is "reported rather than pretended away" — nothing reports it.

**F4 — parseArgs boolean flags are greedy.** `--recursive`, `--comp`, `--refresh` consume a following positional, so `discover --recursive .` fails while `discover . --recursive` works. Flag-order sensitivity in a tool an agent drives from memory is worth fixing (whitelist the value-taking flags, or treat known booleans as such).

**Cosmetic:** `read --span` logs its ledger basis as `d<depth>` because the `@`-anchor falls through the prefix check ([mdnav.mjs:622](skills-dev/doc-dive/mdnav/mdnav.mjs:622)); a kept citation label counts its bytes as elided in coverage; `outline --within` shows only children, so the parent's direct body is invisible in that view — fine for exploration, but a one-line stderr note ("N bytes of direct body not shown") would keep the never-silently-omit promise.

**Test gaps matching the above:** fenced noise, non-`---` breaks, flag-order.

My dogfood run left a `.doc-dive/` under `skills-dev/doc-dive/` — it's covered by the [.gitignore](skills-dev/doc-dive/.gitignore) you already added, so I left it.

---

# The two docs: what reconciliation actually requires

The stack has a clear precedence the notes half-state: **README (settled, tested) > notes (corrective + new) > DRAFT (base, known-lossy)**. Applying it mechanically resolves most apparent conflicts:

**DRAFT text that is now simply stale** — mark or strike, don't reconcile:

- DRAFT §6 gives `outline`/`read` an `--out` flag; the README explicitly refuses `--out` with rationale. README wins.
- DRAFT §6 extents are `body|unit|subtree`; implementation is `unit|subtree`. `body` never got built and nothing mourns it.
- DRAFT §5's artifact layout (`~/.Codex/tmp/investigate-markdown/`, `source.json`, materialized `outline.depth-N.md` files) is triply superseded: the corpus-local `.doc-dive/<stamp>/` layout, the no-`--out` decision, and DRAFT §6's own "sidecar contains no duplicated source body" (which contradicts its own §5 `source.json`).
- DRAFT §13's acceptance criteria are subsumed by the 130-test suite.
- The verb set grew (coverage, locate, profile, marks, `--by breaks`, `--windows`, `--span`, `--strip`) — I checked each against DRAFT §3's non-goals and the notes' admission test: all pass. `profile` is the closest call (cadence flagging _is_ a candidate-delimiter suggestion), but it reports measurements and defends the line carefully.
- Naming: `investigate-markdown-corpus` (DRAFT) vs `doc-dive` (directory, notes, `.doc-dive` artifact dir). De facto settled — say so once.

**The notes' §1 restorations** — I read the DRAFT specifically checking each claim of loss, and all six hold up. The admission test genuinely isn't derivable from DRAFT §3's enumeration; the DRAFT does collapse skill/agent into two layers; §2's prose really is a lossy compression of the observable table. The notes' §2.4 point that the DRAFT _demonstrates_ consolidation-as-attrition-mechanism is earned, not rhetorical.

**Contradiction the notes already flag, endorse it:** DRAFT §2 promises a "cognitive standard library, not a `main()`" and §9 then numbers ORIENT→DELIVER into a pipeline. Notes §5 ("constrain state, not sequence") is the resolution — SKILL.md should carry the moves with entry conditions and lose the ordering.

## Four tensions neither doc resolves

**T1 — The ledger's lifetime contradicts the notebook's invariants.** This is the important one. The notes require: "the notebook is sufficient to resume from nothing" (§5), the read-vs-cited diagnostic (§2.3, "both are recorded"), and a corpus-wide attrition sweep (§4.4). But `reads.jsonl` lives in a per-run stamp directory the README calls "reproducible and disposable — delete to start over," and every `discover` mints a _new_ stamp with an empty ledger. A multi-session investigation therefore fragments its read history across stamps, `coverage` reports only the current run, and the read-vs-cited comparison quietly loses everything before the last re-discover. Either the skill must pin `--run` across sessions (fragile — one absent-minded `discover` resets it), or `coverage` needs a union-across-runs mode, or the ledger graduates to durable the moment a notebook exists. This needs a decision before SKILL.md is written, because the reverse walk and the attrition sweep both stand on it.

**T2 — "Automated" spaced reactivation has no automator.** Notes §1.4 insists rotation of older state is "automated, not left to the agent's discretion" — but mdnav can't do it (it knows nothing of the notebook, and it would fail the admission test's spirit anyway), and "triggers, not schedules" (§5) forbids the obvious alternative. The notes' own priority ladder (§5: tool affordance → schema → trigger → prose) supplies the fix: make it a **schema constraint** — e.g. every dive preamble must name the K least-recently-touched open items, verifiable by inspection of the notebook. But that's a decision, and today the two sections just disagree.

**T3 — §1.3 vs §2.3 on claim dependencies.** §1.3 (recovered from the source session) lists "dependencies on other claims" as a claim _field_; §2.3 argues at length that typed edges are wrong and glue-prose-with-mentions is the affordance. §2.3 supersedes — but the notes never say so, and this is precisely the silent-supersession failure mode the whole document is about. One sentence in §1.3 ("the dependency field is superseded by §2.3's glue") closes it. The reconciled claim schema: anchors-in-glue, source diversity, confidence, descriptive/interpretive/speculative type, dive-order provenance — relations stay prose.

**T4 — Notebook location is undecided.** DRAFT §5 gestures at `<project>/.codex/reviews/<run-id>/`; the README carefully places _navigation_ artifacts and says nothing of the notebook; notes §6 discusses notebook I/O cadence but not location. Combined with T1, "where does durable analytical state live, and what anchors it" is the largest unspecified piece of the design.

**One optional tool suggestion falling out of §2.3:** the read-vs-cited diagnostic needs cited anchors resolved to spans _without_ reading them. Today that means scraping `outline` output. A `resolve <anchor>...` verb (anchor → span, no bytes, no ledger entry) passes all five admission-test questions and would make the walk's batch-check one call. Not urgent; the notes are right that no new tool is _required_.

## Shape of the reconciled SKILL.md

The notes are close to being decomposable directly: layers + admission test up front; FRAME emitting the four parameters with `undetermined` legal (§4.0–4.1); the moves as a library with entry conditions; the notebook schema as invariants (append-only, retraction-not-deletion, anchor conservation under split/merge, split-cites-its-criterion, glue-not-edges, run-order provenance); the three pre-synthesis checks (attrition sweep, reverse walk, read-vs-cited) as triggers; warnings merged from DRAFT §11 + notes §2.2/§3. The long arguments (the RJMCMC section, the KL asymmetry) go to `references/` per your own "write consequences, not commands" — they've each already been distilled to their operational residue in the notes, which makes that split nearly free.

Happy to take any of these as follow-ups: the F1/F2 fixes with regression tests, the doc-drift cleanups, or a first-cut SKILL.md skeleton with the T1–T4 decisions marked as explicit choice points.
