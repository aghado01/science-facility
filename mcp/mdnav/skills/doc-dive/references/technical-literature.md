# Technical Literature & Research Paper Dives

This reference guides deep-dives into academic papers, technical specifications, and research manuscripts transferred to Markdown from LaTeX or PDF sources (single papers or collections).

---

## 1. Unit of Analysis: The Mechanism

In technical literature, the primary unit of analysis is the **Mechanism** (algorithm, data structure, mathematical operator, protocol, or architectural invariant).

Unlike chat threads where proposals mutate along a temporal chain, papers present static assertions that must be reconciled across distinct author vocabularions and formalisms.

---

## 2. Analytical Postures

| Dimension | Synthesis toward Construction | Exploratory / Unlikely Connections |
|---|---|---|
| **Goal** | Extract and adapt algorithms/concepts for a target codebase or engine | Discover cross-cutting invariants across disparate or seemingly unrelated papers |
| **External Model** | An active architecture, codebase, or system design specification | None (emergent model in the notebook) |
| **Reading Order** | Dependency / algorithmic prerequisite order | Breadth-first across problem formulations, depth on connections |
| **Coverage** | Stratified: rigorous on algorithms/claims, proofs checked for boundary conditions | Breadth on abstracts/introductions, depth on connective mechanisms |
| **Termination** | Architectural constraints satisfied with source-grounded mechanisms | Emergent connection articulated or disproven |

---

## 3. Concept Identity & Reconciliation Across Papers

Across a corpus of $N$ papers, the same fundamental object frequently appears under conflicting names, notations, and indexing conventions.

> **Rule:** Establishing concept identity across literature is analytical work, not clerical indexing.

### The Reconciliation Protocol
When encountering related mechanisms across papers:
1. **Key by Operational Behavior:** Index the mechanism by what it *does* rather than what the authors name it:
   ```markdown
   ## M-003 — Dynamic Zigzag Graph Simplification
   - Canonical Function: Replaces boundary cycles while preserving persistence intervals.
   - Aliases:
     - "Zigzag collapse" (Paper A, D001:H0008)
     - "Filtration contraction" (Paper B, D002:H0014)
   ```
2. **Tabulate Regime Assumptions:** Papers often agree on nominal mechanisms but disagree on critical boundary conditions:
   ```markdown
   | Source | Notation | Continuity Assumption | Time Complexity | Metric Space |
   |---|---|---|---|---|
   | D001 (Paper A) | $\mathcal{K}_t \to \mathcal{K}_{t+1}$ | Simplicial complex | $O(n \log n)$ | Euclidean |
   | D002 (Paper B) | $X_i \leftrightarrow X_j$ | Abstract posets | $O(n^2)$ | Arbitrary metric |
   ```
3. **Guard Against Invalid Hybrids:** Merging Paper A's fast algorithm with Paper B's generalized data structure fails silently if their underlying metric assumptions conflict. Record assumption clashes under `Contradictions & Tensions`.

---

## 4. Stratified Reading & Attention Allocation

Academic papers transferred to Markdown contain dense mathematical derivations, LaTeX residue, and routine proof steps. Loading whole papers consumes finite context on verification details rather than structural concepts.

```bash
# 1. Discover and check grain
node mdnav.mjs discover ./papers
# Typical signature: 1/15/22~1.2K (H1 title, H2 major sections, H3 sub-mechanisms)

# 2. Outline major sections
node mdnav.mjs outline D001 --depth 2

# 3. Descend selectively into algorithmic sections
node mdnav.mjs outline D001 --within H0005 --depth 3
```

### Allocation Strategy
- **High-Attention Spans (Read at Depth):**
  - Problem definitions and formal guarantees
  - Core algorithm pseudo-code and data structure definitions
  - Theorem statements and boundary condition lemmas
  - Discussion sections identifying failure modes or empirical limits
- **Low-Attention Spans (Telescope or Skip):**
  - Standard introductory literature surveys (unless tracing citations)
  - Mechanical algebraic derivations and routine induction steps
  - Standard benchmarking hardware boilerplate

---

## 5. Integrating Literature into Project Architectures

When conducting a dive to inform an active software system or tool implementation:

1. **Extract Concrete Interface Contracts:**
   - Map mathematical operators to software functions/types.
   - Identify state invariants that must be maintained across mutations.
   - Note time/space complexity bottlenecks and cache locality implications.
2. **Translate Formalism to Target Language Idioms:**
   - Translate mathematical sets, graphs, or lattices into concrete structures (e.g. bitmaps, sorted arrays, directed adjacency graphs).
3. **Formulate Design Deltas:**
   - Clearly delineate which portions of the literature are adopted verbatim, which are modified for practical engineering constraints, and which are omitted.

---

## 6. Subagent Fan-Out Gating

When reviewing large collections of papers, dividing work across subagents is tempting but dangerous for deep conceptual synthesis.

### The Fan-Out Gate
Delegation to subagents is admissible **ONLY** when all of the following hold:
1. **Commutative Observable:** The task is extracting independent, localized facts (e.g. *“Extract the Big-O complexity table from each paper”* or *“List the benchmark datasets used in each manuscript”*).
2. **Committed Partition:** The document and unit boundaries are fixed in advance.
3. **Evidence, Not Synthesis:** The worker returns literal spans or structured tables, never interpretive judgments.
4. **Cheap Verification:** The orchestrator can verify worker outputs against source anchors in $O(1)$ tool calls.

```
                  ┌─────────────────────────────────┐
                  │ Is extraction commutative and   │─── No ───► Run single-threaded in main agent
                  │ strictly localized to one paper?│
                  └─────────────────────────────────┘
                                  │
                                 Yes
                                  ▼
                  ┌─────────────────────────────────┐
                  │ Are outputs verifiable via byte │─── No ───► Run single-threaded in main agent
                  │ anchors without re-reading body?│
                  └─────────────────────────────────┘
                                  │
                                 Yes
                                  ▼
                  ┌─────────────────────────────────┐
                  │ ADMISSIBLE: Fan out workers for │
                  │ mechanical extraction only.     │
                  └─────────────────────────────────┘
```

> **Synthesis is Single-Threaded:** Composing mechanisms into a cohesive architecture or discovering novel cross-paper connections fails under fan-out because the relational insights exist at the intersection of the documents, not within any single worker's shard.
