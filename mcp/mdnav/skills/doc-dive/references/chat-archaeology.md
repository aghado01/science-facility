# Chat Thread Archaeology & Design Thread Dives

This reference guides investigations into long conversational transcripts and multi-turn design threads (single exports or collections across Claude, Codex, Perplexity, ChatGPT).

---

## 1. The Proposal Lifecycle: Unit of Analysis

In an iterative design conversation, ideas and decisions mutate across exchanges. Unit of analysis is not the turn or the document—it is the **Proposal**.

Every proposal ends in one of five disposition states:

| Disposition | Trace in Later Material? | Recovery Mechanism |
|---|---|---|
| **Adopted** | Yes — explicitly endorsed or assumed by subsequent turns | Forward reading / contextual trail |
| **Refined** | Yes — modified and carried forward | Forward reading / version history |
| **Superseded** | Yes — explicitly replaced by a newer decision | Forward reading / reverse walk |
| **Rejected** | Yes — explicitly declined with reasons | Forward reading / tension log |
| **Silently Dropped** | **No** — unmentioned in later text | **Only via forward ledger + attrition sweep** |

### The Asymmetry of Silent Attrition
Four of the five states leave traces downstream. **The fifth (silently dropped) leaves zero trace.**

> **Core Hazard:** Attrition cannot be found by late sampling. A summary or consolidation written at the end of a session reproduces only what remained salient, losing critical constraints, admission criteria, or design principles that nobody ever rejected.

#### The Attrition Sweep Procedure
1. **Log Forward Cheaply:** As you read forward, log every candidate proposal in the notebook:
   ```markdown
   - [P-014] D001:H0018: Propose 5-point admission test for utility features | Status: open
   ```
   Do not wait to see whether it survives; survival is only known later.
2. **Update Status Upon Recurrence:** When a proposal is adopted, refined, or rejected, update its status and attach contextual glue.
3. **Pre-Synthesis Sweep:** Before writing the final deliverable, sweep the ledger for proposals still marked `open` with no subsequent mention.
4. **Report Attrition Explicitly:** Classify dropped proposals as abandoned tangents or unintended omissions.

---

## 2. Intent vs Decision: Spines and Reply Bodies

### The Heading/Quote Spine
The spine (heading lines, blockquote runs, user prompts) gives the user's intent trajectory cheaply (~5–15% of document bytes).
- **Spine tells you:** What was asked, what goals were established, and when pivots occurred.
- **Spine does NOT tell you:** What was decided, how mechanisms were specified, or how technical details were resolved.

```powershell
# Extract the spine cheaply via marks or depth-1 outlines
node mdnav.mjs outline D001 --depth 1
node mdnav.mjs marks D001 --kind blockquote
```

### Reply Bodies Contain the Design
In technical design sessions, key specifications and architectural criteria frequently originate in assistant replies or brief user ratifications.
- **Rule:** A dive claiming to reconstruct "what the conversation converged on" based only on reading user turns or headings is invalid. Coverage of decision-bearing reply bodies must be real.

### Asides, Hedges, and Ratifications
The highest-leverage inflection points in a design thread rarely announce themselves with major headings:
- *Asides:* ("Well, perhaps contradicting myself a bit, but...") often introduce pivotal design invariants.
- *Hedges & Concessions:* ("Wait, actually...", "Fair point, let's restrict that...") often narrow scope.
- *Ratifications:* ("Agreed on the stopping boundary...") turn transient suggestions into permanent constraints.

---

## 3. Structural Triage & Markup Discriminators

Chat exports from different platforms use idiosyncratic markup patterns. Use `mdnav` measurements rather than hardcoded assumptions.

### Profiling Cadence
```bash
node mdnav.mjs profile D001
```
- Inspect `cv` (coefficient of variation). A construct with `cv < 0.6` spanning the document divides turns.
- Look at the `detail` column (e.g. `powershell×43 json×13`) to see what tools were exercised.

### Mechanical Markup Discriminators
Before inventing content heuristics, inspect platform markup:
- **Codex transcripts:** `<details><summary>N previous messages</summary>` wraps model framing. Use `marks --kind html` to isolate.
- **Claude exports:** Alternating blockquote runs (`marks --kind blockquote`) separate prompt turns from assistant replies.
- **Perplexity exports:** Flat H1/H2 with horizontal rules (`---`). Use `--by breaks` to partition.

### Aggressive Noise Stripping
Transcripts often contain multi-megabyte base64 screenshots (`data:image/png;base64,...`) or ephemeral presigned URLs.
- Always use `--strip all` on chat exports:
  ```bash
  node mdnav.mjs read D001 --heading H0006 --depth 1 --strip all
  ```
- Stripping replaces megabytes of binary noise with addressable markers (e.g., `<!-- mdnav: elided image 404 KiB -->`), preserving context window attention.

---

## 4. Multi-Document & Heterogeneous Threads

Design investigations often span multiple exports across different models (Claude, Codex, Perplexity) addressing a common theme.

### Establish Explicit Chronology
Within a single file, ordering is inherent. Across multiple files, chronology is **not** in the corpus.
- Inverting the chronological order of two threads inverts supersession, turning discarded drafts into "final conclusions."
- Inspect file creation timestamps, git history, or internal references (e.g., "in our earlier session with Codex...").
- **Record chronological assumptions explicitly** in the notebook `Study Contract`.

### Corpus-Wide Proposal Lifecycles
Track proposals across document boundaries:
```markdown
- [P-008] D001:H0012 (Claude thread): Propose byte-span address model.
- [P-008] D002:H0004 (Codex thread): Implemented and refined into [start, end) half-open spans.
```

---

## 5. Marginal Outcome Synthesis

When synthesizing a chat thread or collection, structure the output around marginal outcomes:

1. **Converged Concepts & Architecture:** Core decisions that survived all exchanges, grounded in specific anchors.
2. **User Intent vs Assistant Proposals:** Clearly distinguish user-mandated constraints from model-suggested options.
3. **Design Intent & Rationale:** The *why* behind choices, captured from the contextual glue between turns.
4. **Silent Attrition Inventory:** High-value proposals that were introduced, never rejected, but lost in later summaries.
5. **Unresolved Tensions & Open Questions:** Issues explicitly identified but deferred or left ambiguous.
