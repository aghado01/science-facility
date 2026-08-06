# doc-dive — notes toward SKILL.md

Working notes, not the skill. Collected from building `mdnav`, from a real dive on
`discussion/codex-design-discussion-full.md`, and from auditing what that dive
missed. To be codified later.

Status of the neighbouring documents:

- `md-deep-dive-DRAFT.md` — the converged spec from the Codex session. Still the
  base, but **known to have lost material** from the conversation that produced
  it (see §1).
- `mdnav/README.md` — the tool contract. Settled and tested.
- This file — what the skill must say, and why.

---

## 1. Recovered from the source conversation

The DRAFT dropped several things that were present in the session behind it. All
of these should be restored when the skill is written.

### 1.1 The admission test (highest priority)

DRAFT §3 lists non-goals but not the criterion that generates them. The original:

> 1. Is it deterministic?
> 2. Does it eliminate repeated mechanical work?
> 3. Does it reduce tool calls or context noise?
> 4. Does it preserve literal source material?
> 5. **Does it avoid deciding what the material means?**
>
> If a feature fails the last test, it probably belongs in the reasoning
> procedure rather than the utility.

This supersedes the rule I wrote independently ("presume about the reading
process, never about the content"). Same boundary, but operational — you can run
a proposed feature through it. A list of banned features is an enumeration of
instances; this is the rule.

### 1.2 Three layers, not two

- **Utility** — deterministic structure, byte spans, outlines, literal extraction
- **Skill** — reading discipline, coverage, state maintenance, revisitation
- **Reasoning agent** — document classification, semantic boundaries,
  interpretation, synthesis

The DRAFT collapses the last two. Keeping them apart is what makes "the tool
exposes candidates, the agent decides what they mean" enforceable.

### 1.3 Claims kept separate from concepts

Not in the DRAFT and not in anything I proposed. A claim carries: supporting
observations, contradicting observations, **source diversity**, confidence,
whether it is descriptive / interpretive / speculative, and dependencies on other
claims.

> This makes the final synthesis auditable and exposes conclusions supported only
> by the most recent document.

That last clause is a *mechanism* for detecting recency capture, not an
exhortation to avoid it. And `dependencies on other claims` is not bookkeeping —
it is the affordance the reverse walk (§2.3) runs on. Without it, retracting a
claim leaves everything derived from it silently standing.

### 1.4 Spaced reactivation

The context-pack was to include "a small rotating sample of older state … it
prevents concepts from disappearing simply because they have not appeared
recently." Automated, not left to the agent's discretion. Also: reading-cycle
step 4 was *"reactivate selected older concepts, including stale or weakly
supported ones."*

### 1.5 Epoch reviews

Reconstruct concepts **from the observation ledger**, not from the previous
checkpoint. Compare against earlier checkpoints. Examine abandoned hypotheses.
Check whether recent material has disproportionately shaped the state. Write a new
checkpoint **without deleting prior checkpoints**.

### 1.6 Observable classification

DRAFT §2 compresses this to prose; the table is more precise and should be kept
tabular:

| information type | valid treatment |
|---|---|
| counts, named entities, citations | commutative accumulation |
| chronology, argument development | ordered accumulation |
| definitions that change over time | stateful replacement with history |
| contradictions, conceptual tensions | deferred joins across observations |
| emergent themes, implied assumptions | global interpretation, periodically reconsidered |
| final synthesis | only after coverage and counterevidence passes |

### 1.7 Terminology

Reserve distinct names so "chunk", "IR" and "packet" don't collapse: **source**,
**structural index**, **semantic unit**, **segment plan**, **reading packet**,
**context pack**, **state delta**. With the governing line:

> Structured data controls what the agent reads; it is not itself what the agent
> reads.

---

## 2. Proposal lifecycle — the core of the method

In an iterative design thread the decisions **mutate**. Each reply may reframe the
whole, refine one part, propose a new direction, or quietly abandon an earlier
one, and the direction is not knowable in advance. So the unit of analysis is not
the turn and not the document — it is the **proposal**.

Every proposal ends in one of five states:

| disposition | leaves a trace in later material? |
|---|---|
| adopted | yes — assumed by subsequent text |
| refined | yes — modified and carried forward |
| superseded | yes — explicitly replaced |
| rejected | yes — explicitly declined |
| **silently dropped** | **no** |

**The asymmetry is the whole problem.** Four of the five are recoverable by
reading forward from any point. The fifth is invisible unless the proposal was
recorded when first encountered and later swept for non-recurrence.

Consequences for the procedure:

- **Attrition cannot be found by sampling.** Silently-dropped material is, by
  construction, absent from later text — so any strategy that samples late
  material or trusts a consolidation will miss exactly it.
- **Log proposals as you read forward**, cheaply: anchor + one line + status
  `open`. Do not wait to see whether they matter; that is knowable only later.
- **Sweep before synthesis** for proposals still `open` with no subsequent
  mention. Those are the attrition set, and they are the highest-value finding in
  a design thread — nobody decided against them.
- The dormancy check (§1.4) and the attrition sweep are the same operation.

### 2.1 A valid partition is not a work queue

`mdnav` produces a byte-exact partition: 62 units, no overlap, nothing dropped,
verified. That is precisely what a work queue looks like, and the tool therefore
manufactures the temptation it exists to resist. **State the distinction
explicitly in the skill**, because the cleaner the partition, the more obviously
distributable it appears.

The reason it isn't is not that workers summarise badly. It is that the findings
worth having are not located in any unit:

- **Ideas are chiselled, not stated.** In an iterative thread an idea is
  approached repeatedly from different angles and its final shape is the
  *intersection* of many partial statements. "What does minimally invasive mean
  here" is answered by four turns jointly and by none of them alone. That is a
  path functional over the sequence, not a property of a span.
- **Absence has no location.** The highest-value finding in the audit was that
  the admission test never reached the DRAFT. No unit contains that. A reader
  given the consolidation sees a coherent list with nothing visibly missing; a
  reader given the section sees a fine test with no reason to flag it. Both are
  locally correct and the finding is in neither.
- **Supersession is relational.** That the test supersedes a rule proposed forty
  sections earlier is knowable only while holding both.

So the partition is real and useful — for *navigation*, for coverage arithmetic,
for re-reading a cluster. It licenses addressing, not distribution.

Corollary for the notebook: a concept whose development trail carries a single
anchor, in a thread of many turns, is either genuinely local or **under-traced**.
Anchor spread across distant turns is a cheap quality signal on whether an idea
was actually read across the conversation or just picked up where it was loudest.

### 2.2 Asides carry disproportionate weight

Both turns lost in the dive were of this shape — one an aside ("well, perhaps
contradicting myself a bit, but…", which turned out to specify the tool) and one
a ratification ("agreed on the stopping point boundaries…", which fixed the
non-goals). Neither announces itself. Both sat structurally adjacent to model
quotes, which is exactly where merge errors occur.

A reframe, a hedge, a concession and a "wait, actually" are where the direction
changes in a design thread. They read as low-salience and rank low to anything
scoring passages independently.

### 2.3 The reverse walk — audit the trail, don't re-run it

Before synthesis, walk the surviving claims **backward** and check each against
its anchors. Direction is the whole point:

- **Forward** re-reading re-runs the derivation. You meet the evidence, then the
  claim, and the claim looks justified — you have reproduced the drift, not found
  it.
- **Backward** you hold the claim first and then look at what is supposed to
  support it. Same spans, same anchors; one is a re-derivation, the other is a
  test. It is the falsification-seeking criterion turned on your own notes.

Cost is bounded by the size of the synthesis, not the corpus — only claims that
survived into the deliverable get walked, and their anchors batch-read in one call
each.

Per claim, four checks:

1. Does the span support the claim **as currently stated**, or only as originally
   stated? Formulations drift while anchors stay put.
2. Were any supporting notes since **retracted or superseded**?
3. Was it formed during **burn-in**, under a frame that did not exist yet?
4. Does the `@digest` still match — i.e. has the source shifted under the anchor?

#### What this requires: contextual glue, not a dependency graph

The affordance the walk runs on is *not* a typed `depends_on` edge. Typing a
relation at write time decides what it means before that is knowable, and a wrong
type is worse than prose because it gets mechanically trusted later. The relation
vocabulary is also open — sharpens, contradicts, instantiates, supersedes,
motivated-by, same-object-under-another-name — and any closed set will be wrong
for some corpus. Same argument as refusing to enumerate postures.

What is wanted is **contextual glue between the anchors**: the trail written as
prose with anchors embedded, rather than a field holding a list of them.

```
Development: D001:H0003, D001:H0019, D002:H0007
```

```
Development: proposed at D001:H0003 as a general principle; narrowed at
D001:H0019 when the paper case broke it; named at D002:H0007.
```

Barely longer, and only the second is testable — the reverse walk can ask whether
H0019 actually narrowed it and check the span. A bare anchor list offers nothing
to falsify. This is "write consequences, not commands" (§5) applied to the
notebook's own schema: the glue is what makes a trail a *development* rather than
a citation list.

Cross-note relations ride the same mechanism. Mentioning another note's id in the
glue is enough: **"what mentions C-002?" is a text search**, and whether C-004
survives C-002's retraction is a judgment that should not be automated. Mention is
mechanical; interpreting the mention stays reading. Annotate liberally while
reading forward — it costs a clause and it is the moment the relation is actually
in view.

**Note provenance in run-time.** Each note should carry which dive wrote it, so
the walk can discount the early ones. Order is part of a note's evidential
status, not incidental to it.

#### Reversibility as a design constraint (the RJMCMC part, properly)

With a retrospective pass in play, the dimension-changing machinery stops being a
metaphor and becomes a requirement on the note format. In RJMCMC a move is
admissible only if its **reverse move exists and is computable**; a sampler that
can split a component but never merge it back is not reversible and does not
target what you think it targets.

The interpretive moves, and what makes each reversible:

| forward move | reverse | what makes it reversible |
|---|---|---|
| **split** a concept that was conflating two things | merge | the children's anchor sets, whose union must equal the parent's |
| **birth** — a new concept from a passage | retract | the motivating anchor, retained |
| **refine** a formulation | restore the prior one | the previous formulation kept, not overwritten |
| **descend** to a finer partition | ascend | byte spans are depth-invariant |
| **adopt** a proposal | un-adopt | the glue recording why it was adopted |

**The irreversible move is precisely the drift-producing move.** Overwriting a
formulation in place destroys the reverse, and the walk cannot pass back through
it. Which unifies three rules previously listed separately — epoch reviews that
never delete prior checkpoints (§1.5), retraction records rather than deletions,
and revision-in-place-with-history — as one principle rather than three habits.
They are not sentimentality about history; they are what makes the audit possible.

#### Conservation of evidence: the Jacobian, non-shallowly

Earlier the Jacobian was used only for coverage — unit counts are not comparable
across a depth change, so measure in bytes. The sharper version applies to
concepts.

If C-004 carries eight anchors and is split into C-004a and C-004b, the anchors
**partition**; they are not inherited twice. Otherwise the split manufactures
support — two concepts each claiming eight anchors where there were eight in
total — and the synthesis then reports two well-evidenced concepts where there was
one. That is a change of measure on the evidence, unaccounted for.

> **Anchors are conserved under split and merge.**

Checkable, and exactly what a reverse walk through a split should verify.

#### Dimension matching: a split must cite what it split on

An RJMCMC split needs auxiliary variables — the parent alone does not determine
the children, so extra degrees of freedom have to be supplied. The analogue: a
concept cannot be split without a **distinguishing criterion**, and that criterion
comes from a passage, never from the concept being split.

So a split move records the anchor that motivated it. Without it the move is
irreversible in practice — you cannot merge back, because you no longer know what
you split on.

#### What the reverse walk is, in these terms

Forward reading is a trajectory through interpretation space with dimension
changes along the way. The reverse walk retraces it and checks each move was
**admissible**: that a reverse existed, that evidence was conserved, that the
auxiliary criterion was recorded. It is an audit of the chain, not a new sample.

And it says why that matters without moralising: if the chain was not reversible,
the conclusion is not a sample from "interpretations this corpus supports." It is
a sample from something else, and no amount of fluency in the write-up fixes that.

#### The forward/reverse asymmetry, and the one thing it makes computable

The asymmetry has a recognisable character. Reverse KL, `D(Q‖P)`, is
**mode-seeking**: Q may ignore whole regions of P for free, since the penalty is
only for putting mass where P has none. Forward KL, `D(P‖Q)`, is
**mass-covering**: Q is penalised unboundedly for having no support where P does.

- A forward read with sampling behaves like the first. It finds a mode — the
  trajectory — and is confidently narrow, and assigning zero weight to the
  admission test costs it *nothing*. Silent attrition is not a lapse in that
  regime; it is what the objective rewards.
- The audit asks the second question: is there support in the corpus you gave zero
  weight? That is the one with the unbounded penalty, which is why attrition
  detection needs near-total coverage rather than better sampling.

Useful as an explanation of why the two passes find different things. Not
computable: there is no P, no Q, no measure over interpretations, and attaching a
number would be theatre.

What *is* computable, from artefacts that already exist — the read ledger holds the
spans read, the notebook holds the spans cited:

> **Compare the distribution of bytes read against the distribution of bytes
> cited.** Both are over the same byte space, both are recorded, and the mismatch
> is arithmetic.

Two diagnostics fall out:

- **Read but never cited.** Either the material was genuinely irrelevant — say so,
  that is a finding — or it was read and dropped, which makes it an attrition
  candidate. The sweep in §2 has somewhere concrete to start.
- **Cited far beyond what was read around it.** Salience capture: a claim anchored
  to one span whose neighbours were never opened may be locally true and
  contextually wrong. This is the checkable form of "supersession is relational".

Neither requires a new tool. `coverage` already reports spans read; the anchors are
in the notebook; the comparison is a set operation over byte ranges.

#### Where to stop

What transfers is the **bookkeeping discipline** — reversibility as a constraint,
conservation under dimension change, auxiliary information recorded at the move,
and the read-vs-cited comparison above. What does not transfer is the mathematics:
no target distribution, no acceptance ratio, no detailed balance as a theorem, no
divergence with a number attached. Writing any of those down would be the same
pseudo-rigor flagged against over-formalising epistemic value (§5), and it would
invite performing the ritual instead of doing the check.

The test for whether a borrowed formalism has earned its place: **does it change
what gets recorded, or only how it is described?** Reversibility changed the note
format. Conservation gave a checkable invariant. Dimension matching added a
required field. The KL framing earned one diagnostic and no arithmetic — which is
the honest yield, and more than nothing.

#### Leonard's tattoos, and the one advantage over him

His failure is not lost notes. It is that he cannot tell which tattoos were
written under a false belief; that "don't trust his lies" was written *because of*
a conclusion he had already reached, with the dependency unrecorded; that he
chose which note to write in order to steer his future self; and that he destroyed
the evidence that would have settled it.

Three of those are live hazards here. The fourth is the asymmetry that makes the
audit possible at all: **sources are immutable and anchors are exact**, so the
evidence cannot be burned — and the digest catches the case where it moved.

### 2.4 A consolidation is not a record

Demonstrated on this corpus: the DRAFT was written as an end-of-session
consolidation and lost §§1.1–1.5. Nothing rejected them. They simply stopped
being salient, and a summary written from context reproduces what is salient.

> **The consolidation is the attrition mechanism.**

Which is the empirical case for the conversation's own rule — rebuild checkpoints
from the ledger, never from the latest summary. Where a synthesis must be written
from context, the attrition sweep has to run first.

---

## 3. Reading strategy findings

### 3.1 The spine tells you what was asked, not what was decided

Blockquote/heading spines give the intent trajectory cheaply (~7–15 % of bytes)
and are the right first pass. But in a *design* conversation the replies contain
the design: §§1.1, 1.3 and the `audit` verb appear in **no** user turn and were
underivable from the spine.

- Question about **development or trajectory** → the spine carries it.
- Question about **content, decisions or outcomes** → reply bodies are primary
  source; coverage must be real.

A dive reporting 10.6 % coverage while describing "what the conversation
converged on" is a category error, and the coverage number said so.

### 3.2 Prefer structural discriminators over stylistic ones

The Codex export wraps the model's framing messages in
`<details><summary>N previous message</summary>`. That is a mechanical
discriminator for 11 of 36 blockquote runs, sitting in the document's own markup.
I used a lowercase-initial style heuristic instead and got it wrong twice.

**Rule:** before inventing a content heuristic, check whether the document's
markup already separates the categories. `marks --kind html` shows it.

### 3.3 Never hand-roll structural extraction

I wrote an ad-hoc blockquote extractor that failed to close runs on blank lines,
merging a user turn into the model quote above it. It hid the turn that specifies
the tool. **I then made the identical mistake in the audit of that mistake.**

Improvised extraction fails silently and the damage surfaces downstream looking
like a reasoning error. Use `marks`; it closes runs on blank lines and there is a
regression test for exactly this.

### 3.4 Outcome scoring cannot reach the findings that matter most

An exam has a ground truth of things *present*. The highest-value finding class
here is an **absence** — a proposal nobody rejected that simply stopped being
mentioned — and absences do not appear in answer keys. That is a property of the
format, not a gap in any particular benchmark.

So the skill is evaluated on **process legibility**, not output quality: coverage
in bytes, anchored claims, the attrition sweep, the reverse walk. None of them
score the synthesis; all of them make the reading inspectable enough to tell
whether a conclusion was earned. Same move as pre-registration and controls —
when you cannot verify the outcome, constrain the process and make it auditable.

The two checks in §5 (narration, divergence) are in that spirit and are not
sufficient; they detect over-prescription, not under-reading.

### 3.5 Coverage is a claim about what you read

Elided bytes are not read bytes. A unit that is 99.5 % screenshot contributes
~2 KB of reading, not 406 KB, and `coverage` now reports it that way.

---

## 4. Analytical posture varies; the loop does not

**Everything above is one posture** — design-thread archaeology — and these notes
over-fit it. Posture is set by the *question*, not by the material.

The examples below are **calibration, not a taxonomy**. They are shapes that have
come up, recorded so the dimensions are visible. They are not a set to choose
from, and a real request will usually sit between them or outside them.

| | **archaeology** | **synthesis toward construction** | **exploratory / "unlikely connections"** |
|---|---|---|---|
| example | "what did this session converge on" | "these PH-zigzag papers, toward a zigzag engine" | "I've been looking at these papers and I see connections I can't articulate — dig in" |
| corpus | one long thread, or **several across different models and exporters, common theme** | N papers, related | N papers, **possibly unrelated** |
| unit of analysis | the **proposal** | the **mechanism** | **undetermined** — emerges |
| ordering | chronological, load-bearing | dependency / construction | unknown; possibly none |
| central difficulty | supersession and silent attrition | **reconciliation** — same object, different notation | naming the question at all |
| contradictions | a mutation to trace | a difference of regime; identify it rather than adjudicate | may be the finding |
| external model | none | **sometimes** an artefact under construction — often not, and often one that never comes to exist | none |
| coverage | near-total, or attrition is invisible | stratified — claims and algorithms close, proofs skipped | breadth first, depth on what connects |
| done when | trajectory reconstructed, attrition swept | constraints satisfied, with sources | the connection is articulable, or shown not to hold |

### 4.0 Parameters may legitimately be `undetermined`

The exploratory case is the common one, not the edge case, and it breaks any
fixed framing: the question is **under construction alongside the answer**. There
is frequently no external artefact — the engine may never come to exist — and no
statable unit of analysis until the material has been seen.

So FRAME must not be read as "state these four things before starting." DRAFT §2
already says *avoid forcing an ontology before encountering the material*, and
naming a unit of analysis prematurely is exactly the frame lock-in that burn-in
warns about. `undetermined` is a valid, expected value. What FRAME owes is:

- the parameters named as **open questions**, not answers;
- a note when one resolves, and what resolved it;
- a note when one is **revised**, since that is a dimension change and prior
  coverage arithmetic may no longer be comparable.

### 4.1 Do not add modes. Make FRAME emit parameters.

Enumerating postures would be the `view.json` mistake one level up. The loop is
already scale-invariant and typed over epistemic state; what changes between
postures is a small parameter set, each entry of which may be `undetermined`:

1. **Unit of analysis** — proposal · mechanism · claim · event · entity · *tbd*
2. **Ordering** — chronological · dependency · construction · none · *tbd*
3. **External model** — none, or an artefact the corpus is read *against*
4. **Termination** — trajectory reconstructed · saturation · constraints satisfied

DRAFT §9's FRAME gestures at this ("which observations are local, which must
preserve temporal order") without naming the parameters. Naming them is what lets
one loop serve any posture without a mode switch. What gets stated back to the
user is a **current reading of the material**, revisable — not a commitment taken
before the material has been seen.

### 4.2 The selection criterion is constant; the model differs

> Prefer the read most likely to change the current model.

In archaeology the model is an interpretation of the corpus. In synthesis it is
the design taking shape — which usually does **not** exist yet, and may never.
In the exploratory case it is a hunch not yet articulable.

Same criterion throughout, different object — which is why it needs no restating
per posture. Where an external artefact *does* exist, the notebook must carry a
representation of it or evidence has nothing to be scored against; where it does
not, the model is whatever the notebook currently says, and the criterion still
works unchanged.

### 4.3 The fan-out gate gives different answers per posture — as designed

Synthesis-toward-construction admits genuine fan-out for part of the work: *"extract each paper's
algorithm statement and complexity bound"* is a commutative observable over a
committed partition with ξ inside one document. It passes the gate. The
composition step — how those mechanisms combine into one engine — fails it, hard.

Archaeology admits none, because even the extraction is relational: what a turn
proposes is only determinable against what preceded it.

That the same test yields opposite answers on the same corpus shape is the point.
A flat prohibition would be wrong for B; a reflex to fan out would be catastrophic
for A. Keep the gate typed.

### 4.4 Archaeology is often multi-document, and heterogeneous

The design-thread case frequently arrives as **several threads across different
models and exporters** — Claude, Codex, Perplexity — sharing a theme rather than a
format. Three consequences:

- **Per-document basis selection earns its keep.** One corpus may need `--depth 1`
  for an H1-delimited export, `--by breaks` for a Perplexity dump, and a
  blockquote recipe for a Codex transcript. This is the concrete payoff for
  refusing a corpus-wide mode.
- **The proposal lifecycle spans documents.** An idea proposed in one thread may
  be adopted, mutated or silently dropped in a later one with a different model.
  The attrition sweep is corpus-wide, not per-document.
- **Cross-document chronology is not in the corpus.** Within a thread, order is
  given. Across threads it is not — and getting it wrong *inverts supersession*,
  turning the superseded version into the conclusion. Establish it explicitly
  (export timestamps, filesystem mtimes, or content that references another
  thread) and **record it as an assumption**, because it is one.

### 4.5 Reconciliation is a version of concept identity

In archaeology, a concept's identity is its anchor set inside one document. Across a
paper corpus the same
object appears across N papers under different names, notation and indexing
conventions, and **establishing that they are the same object is the analytical
work**, not a preliminary to it. The notebook needs a mechanism entry keyed by
what the thing *does*, with per-source aliases and the assumptions each source
attaches — because two papers agreeing on a name and disagreeing on assumptions is
the failure that silently produces an unimplementable design.

## 5. Skill shape (carried forward from design discussion)

- **Constrain state, not sequence.** Name the moves and their entry conditions;
  do not order them into a pipeline. DRAFT §2 calls for a "cognitive standard
  library" and DRAFT §9 then contradicts it by numbering the verbs.
- **Triggers, not schedules** — `when <observable condition> → <operation>`.
- **Invariants over procedures**: the notebook is sufficient to resume from
  nothing; every claim carries an anchor; coverage is measured in bytes at a
  stated grain; nothing is delegated that isn't a commutative observable over a
  committed partition.
- **Convert posture into structure wherever possible.** Priority: tool affordance
  → schema/invariant → trigger → prose. Prose is the weakest and drifts; a
  required notebook field does not.
- **Write consequences, not commands** — compress the reason into the rule as a
  clause, keep the argument in `references/`.
- **Selection criterion:** prefer the read most likely to *change* the current
  interpretation, not merely to add to it.
- **Stop on saturation, not coverage** — provided the unread remainder is
  characterised.

Recursion: the loop is scale-invariant (corpus / document / unit / concept) and
typed over epistemic state rather than over document objects. That is what makes
it compact and transferable. Base cases: descent stops when a unit is small
enough for uniform attention; the loop stops on saturation.

---

## 6. Open items

- **Fan-out gate** — typed permission (commutative observable, committed
  partition, ξ < ℓ, evidence not interpretation, declared return schema, cheap
  verification). Portable, since a host without subagents simply never satisfies
  it.
- **Notebook I/O discipline** — append between checkpoints, compact at INTEGRATE.
  Read-modify-write per dive is likely the largest unshielded overhead.
- **Cross-host packaging** — canonical body in `utils/skills/doc-dive`, junctions
  into `~/.claude/skills` and `~/.codex/skills`, thin per-host activation stubs.
  No host-branded paths in the body; work dir is a parameter.
- **Whether `marks` needs a blockquote-run *spine* recipe** or whether the
  documented recipe suffices. Recurrence on other documents will decide.
- **`html` noise filter is unvalidated at scale** — the corpus tested against was
  hand-pruned.
- `signed-url` has zero true positives locally; verified only for absence of
  false positives.
