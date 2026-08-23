Firing up the adjutant per the standing pattern — first the pattern's memory file, the TeXdig issues layout, and the para-agent schemas:

Completed in 11.5 minutes, exit 0. Fetching the receipt and the deposited report:

agy ran, deposited, and the report is committed: [agy-cut23-lane-scoping-20260812_133800.md](issues/TeXdig/discussion/agy-cut23-lane-scoping-20260812_133800.md) — 651 lines, per-lane cutlines, an owner-decision index, and an unknowns-with-evidence section. Receipt: 65 turns, ~11.5 min, $5.13, session `ea4d81db-5665-421f-aa07-8fe3a8456664` for `--resume` follow-ups. It handled tool denials gracefully (wanted Bash for corpus aggregation, got denied, fell back to grep sampling).

**Triage verdict: this was a strong run.** I spot-verified every load-bearing claim against code I wrote myself, and all held exactly:

- **Environment definitions have no `def:` ids** — `compile/macros.ts` filters `macro-definition` only, so theorem-like and diagram zone _closure is currently inexpressible_. Real gap, and it's the first thing zones would hit.
- **`reconcile.ts:454` drops the `bracketed` flag** when flattening `argumentSpans` — so `\cite[Theorem 1.11]{Kirilov}` (28 such sites in the corpus) would hand pointer-key extraction the optional note instead of the key. Cheap census fix, load-bearing for pointers.
- **Paragraph boundaries don't survive into the stores** — `parbreak` is lumped with `string`/`whitespace` in textRuns. That's why its sequencing puts walk _last_, behind a census-tier fix.
- **seq renumbers when the item set grows** — adding walk nodes shifts every `macros.jsonl` seq already on disk. The contract anticipated integer-distrust, but cross-cut stability is a real question now, not later.
- **The governing-definition resolver exists in two subtly incompatible copies** (my `expand.ts` and `macros.ts` versions differ in fallback behavior) — and zones would need a third. Extract-first is its sequencing recommendation, and it's right.

**The two best pieces of talk-back are genuinely yours to rule on:**

1. **`bound-out-of-scope` evidence basis.** It rejected the tempting document-level answer (configured-gap membership — fires on 34/34 papers, can't tell a typo from `\dfrac`) and proposes three per-name bases: a lexical _binder register_ over the in-tree `.sty`/`.cls` files (verified viable — `kbordermatrix.sty:73` defines `\kbordermatrix`, which that paper really uses in math), the configured/ctan channel, and a read-only latex2e kernel lookup. But it correctly flags that the binder register collides with README doctrine — unparsed files get sha attestation "_nothing more_," and a name index is more. That's a doctrine amendment only you can make.
2. **Pointer-hood's base case.** `\ref` is invoked 1,473 times and defined zero times — transitive derivation has nothing to recurse into without a seed. Its framing: the doctrine forbids a fixed vocabulary as the _answer_, not as the _seed_. And it brought corpus counter-examples in both directions: `\theoremofref`/`\propositionofref` look maximally ref-shaped but are title-text holders, while `\descitem` carries `\refstepcounter` — an _anchor-target-forming_ class that `PointerRecord`'s two-member union has no room for.

Its sequencing: shared resolver extraction → pointers → math/verbatim/float zones (theorem-like waits on env-def ids) → parbreak fix + walk. The report's section 6 is the decision queue when you want to work through it — and the adjutant's session is resumable if you want to argue with any of it.
