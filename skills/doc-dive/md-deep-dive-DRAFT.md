## Converged design specification v0.1

Provisional names:

- Skill: `investigate-markdown-corpus`
- Navigation utility: `mdnav`

The system empowers one reasoning agent to conduct open-ended investigation, research, interpretation, and synthesis across one or many Markdown documents without loading the corpus wholesale or reducing it to independent summaries.

The tools expose structure and literal source spans. The skill supplies a stateful investigative discipline. The agent retains semantic control.

## 1. Scope

Supported requests include:

- A single long Markdown document
- An explicit list of Markdown files
- A mixture of files and directories
- A directory containing documents of interest
- Chat-thread exports
- Academic papers transferred from LaTeX or PDF sources
- Heterogeneous collections combining those forms
- Open-ended questions whose relevant concepts and relationships are not known in advance

The framework must not assume a fixed output such as “summarize every document.” The user’s investigative question determines what is measured, tracked, compared, and ultimately synthesized.

## 2. Governing principles

### Attention is the investigative instrument

Expose source material at a deliberate semantic grain. Do not flood the reader with the entire corpus or with machine-oriented container formats.

### Structure informs navigation without determining meaning

Markdown headings provide deterministic access points. The reasoning agent decides what those headings mean in each document.

### Documents remain independent structural atoms

Discovery is corpus-wide. Structural projection and reading depth are document-local.

### The source remains authoritative

Never mutate source documents. Derived indexes, outlines, and reading packets are disposable projections.

### Preserve provenance across interpretation

Durable claims and concept revisions must remain traceable to document and section anchors.

### Accumulate according to the observable

Treat different analytical products differently:

- Mechanical facts may be accumulated commutatively.
- Chronology and conceptual development require ordered accumulation.
- Contradictions and relationships may require deferred comparison.
- Emergent interpretations require periodic global reconsideration.
- Final synthesis follows coverage and counterevidence review.

### Guidance is a cognitive standard library

Offer reusable investigative operations rather than a rigid `main()` procedure. Let the agent select and combine them according to the question and material.

## 3. Explicit non-goals

The utility must not perform:

- Automatic document classification
- Semantic chunking by a model
- Summarization
- Concept extraction
- Relevance ranking
- Embedding generation
- Reading-order selection
- Notebook mutation
- Cross-document synthesis
- Automatic document repair
- Source rewriting
- TOC insertion
- Reading-cursor orchestration
- Agent delegation
- MCP wrapping unless later justified

These remain reasoning responsibilities or future additions supported by observed need.

## 4. Atomic model

```text
Review
├── Requested source scope
├── Discovered document inventory
├── Document D001
│   ├── Immutable Markdown source
│   ├── Complete heading index
│   ├── Zero or more projected outlines
│   └── Literal reading units
├── Document D002
│   └── ...
└── Investigative state
    ├── Coverage
    ├── Evidence
    ├── Developing concepts
    ├── Questions and contradictions
    └── Integration checkpoints
```

Document-local anchors are namespaced:

```text
D001:H0003
D002:H0012
```

The sidecar resolves those identifiers to exact source byte spans.

## 5. Working artifacts

Navigation artifacts are transient:

```text
~/.Codex/tmp/investigate-markdown/<run-id>/
├── inventory.md
├── documents/
│   ├── D001--claude-guidance--b4000a41/
│   │   ├── source.json
│   │   ├── headings.index.json
│   │   └── outline.depth-1.md
│   └── D002--harness-effect--057fcd58/
│       ├── source.json
│       ├── headings.index.json
│       ├── outline.depth-2.md
│       └── outline.depth-3.md
└── packets/
    └── current.md
```

If a review must survive sessions, its analytical state may live in:

```text
<project>/.codex/reviews/<run-id>/
```

Navigation indexes remain reproducible and disposable. Analytical notes may be durable.

The skill should avoid creating a large file hierarchy unnecessarily. A small investigation may need only:

```text
review-state.md
```

A large investigation may separate evidence and concept history when the combined notebook becomes inefficient.

## 6. `mdnav` utility contract

### Discover

```powershell
mdnav discover <file-or-directory>... `
    --glob '*.md' `
    --recursive `
    --work-dir <path>
```

Responsibilities:

- Respect only user-provided scope.
- Resolve explicit files and directory members.
- Deduplicate resolved paths.
- Assign concise run-local document IDs.
- Record source path, byte length, hash, and heading counts.
- Build one complete heading index per document.
- Produce a compact inventory.
- Avoid emitting document bodies.

It does not decide which discovered documents are conceptually relevant. The agent reviews the inventory and user request.

### Index

```powershell
mdnav index <file> --work-dir <path>
```

Responsibilities:

- Read source bytes without modifying them.
- Recognize valid Markdown headings outside code fences.
- Record byte and line locations.
- Compute parent relationships and structural extents.
- Record source hash, size, encoding, and newline form.
- Reuse a valid sidecar when possible.
- Reject or refresh stale sidecars explicitly.

The sidecar contains no duplicated source body.

### Outline

```powershell
mdnav outline <file-or-document-id> `
    --max-depth <1-6> `
    [--within <heading-id>] `
    [--out <path>]
```

`--max-depth` is document-local and query-local:

- `1`: H1 headings are active.
- `2`: H1–H2 are active.
- `6`: H1–H6 are active.

Headings below the selected depth remain literal content inside the enclosing unit.

Default output is concise Markdown or plain text:

```text
[H0005] H2  direct=47 B      subtree=4.96 KiB  Token Economics...
[H0009] H2  direct=29 B      subtree=15.65 KiB The Writer Agent Harness
[H0014] H2  direct=23 B      subtree=3.47 KiB  Experimental Setup
```

Defaults:

- Truncate exceptionally long heading titles.
- Show full titles only when requested.
- Report direct and subtree sizes.
- Avoid raw JSON output unless explicitly requested for debugging.

`--within` permits local exploration. For example, the agent may preserve H1 exchanges globally while examining H2 headings within one unusually structured response.

### Read

```powershell
mdnav read <file-or-document-id> `
    --heading <id> `
    --max-depth <1-6> `
    --extent <body|unit|subtree> `
    [--out <path>]
```

Extents:

- `body`: Begin after the heading line.
- `unit`: Begin at the heading and end at the next heading active under the chosen maximum depth.
- `subtree`: Begin at the heading and end at the next active heading of the same or higher rank.

Standard output must contain only literal Markdown source bytes. Put diagnostics on standard error.

If `--out` is supplied, write the exact materialized reading packet there.

### Documents without usable headings

To preserve systematic coverage:

- Represent content before the first active heading as `PREAMBLE` when nonempty.
- Represent a headingless document as a single `BODY` unit.
- Include trailing content in the last active unit.
- Never silently omit bytes because a document lacks the expected structure.

## 7. Heading-index behavior

The initial implementation should adapt the legacy byte-indexing principles:

- Scan raw bytes.
- Decode lines only for structural recognition.
- Address content using half-open byte spans: `[start, end)`.
- Handle LF and CRLF.
- Preserve UTF-8 and multibyte Unicode.
- Recognize backtick and tilde fences.
- Track the opening fence character and length.
- Ignore heading-like text inside fences.
- Preserve raw heading text.
- Treat source hashes as stale-index guards.

ATX headings H1–H6 are the required initial syntax. Setext support can follow if encountered in real corpora; the initial tool should at least detect and report probable unsupported Setext headings rather than silently giving a misleading outline.

## 8. Per-document depth semantics

The skill selects depth independently for every document.

For an H1-delimited chat:

```powershell
mdnav outline chat.md --max-depth 1
mdnav read chat.md --heading H0003 --max-depth 1 --extent unit
```

H2–H6 headings inside the model response remain part of the exchange prose.

For a paper:

```powershell
mdnav outline paper.md --max-depth 2
mdnav outline paper.md --within H0009 --max-depth 3
```

The agent can begin at major sections and descend selectively.

The skill may record:

```markdown
| ID   | Source         | Working depth | Structural interpretation                 |
| ---- | -------------- | ------------: | ----------------------------------------- |
| D001 | chat-export.md |             1 | H1 delimits exchanges                     |
| D002 | paper.md       |             2 | Major paper sections; descend selectively |
```

This is investigative state, not corpus-wide utility configuration.

## 9. Procedural cognitive standard library

### ORIENT

Establish:

- The user’s question
- Requested output
- Source scope
- Desired depth
- Whether development order matters
- What kinds of evidence or relationships may matter

Discover the document set, inspect the compact inventory, and preview document outlines without ingesting bodies unnecessarily.

### FRAME

Translate the request into an evolving measurement plan:

- Which observations are local to a passage?
- Which must preserve temporal or argumentative order?
- Which require comparison across documents?
- Which hypotheses should remain provisional?
- What counterevidence would weaken the emerging interpretation?

Avoid forcing an ontology before encountering the material.

### PLAN

Choose:

- Initial document order
- Working depth per document
- Whether to read a whole subtree or descend
- Minimal analytical state needed to preserve continuity

Treat the plan as revisable.

### DIVE

Read one semantically coherent unit as literal Markdown.

Before reading, reactivate:

- The active research question
- Relevant developing concepts
- Applicable unresolved questions
- Any earlier interpretation that this unit may test

Use attention on the source rather than on metadata containers.

### SURFACE

After a dive, record:

- Material evidence and its anchor
- What changed in the developing interpretation
- Which earlier ideas gained or lost support
- Contradictions or ambiguities
- Questions to carry forward
- Coverage progress

Do not make an isolated passage summary the primary durable state.

### INTEGRATE

At natural boundaries—major section, document, thematic epoch—reconsider:

- The document’s internal trajectory
- Concept development over time
- Cross-document relationships
- Early evidence in light of later material
- Counterevidence and abandoned interpretations
- Whether recent material has become disproportionately salient

Build new checkpoints from evidence and revision history rather than recursively compressing the latest summary.

### REVISIT

Return to earlier anchored passages when:

- A later passage changes a definition
- Two sources appear to disagree
- A concept has not been reconsidered recently
- A global claim depends too heavily on recent evidence
- The agent needs to distinguish the user’s idea from a model reply’s elaboration
- An inferred relationship lacks direct support

Search may locate candidates, but it must not substitute for systematic coverage.

### ADJUDICATE

Before final synthesis:

- Audit requested-source coverage.
- Inspect evidence from early, middle, and late portions.
- Test major claims against counterevidence.
- Distinguish observed, inferred, and speculative claims.
- Preserve unresolved ambiguity.
- Verify cross-document claims against their source anchors.
- Identify exclusions and unread material honestly.

### DELIVER

Shape the response around the user’s request rather than around the mechanics of the workflow.

Provide:

- The requested synthesis or analysis
- Source-grounded support
- Important tensions and uncertainties
- Coverage qualifications when material was excluded or unread
- Navigation artifacts only when useful to the user

## 10. Default analytical state

For a modest review, use one concise Markdown notebook:

```markdown
# Study contract

# Document plan and coverage

# Developing concepts

# Evidence anchors

# Contradictions and open questions

# Integration checkpoints
```

Concept entries should preserve revision:

```markdown
## C-004 — Guidance as cognitive infrastructure

Current formulation:
...

Development:

- Initially observed in D001:H0002.
- Refined by D001:H0003.
- Economically grounded by D002:H0006.

Counterevidence or limitations:
...

Open question:
...
```

This is more useful than a chain of segment summaries because it records conceptual change.

## 11. Warnings embedded in the skill

- Whole-corpus ingestion invites attention dilution and middle amnesia.
- Repeatedly summarizing summaries causes provenance and nuance loss.
- Semantic search finds what the reader already knows to ask for.
- A Markdown heading’s semantic role is document-dependent.
- Chat reply headings may organize prose without delimiting exchanges.
- Fluent model replies are not evidence that the user adopted their proposals.
- Recent material can silently redefine the interpretation of earlier material.
- Durable notes prime future reasoning; hypotheses must not be recorded as facts.
- Excessive procedural machinery can displace the reasoning the system exists to support.

## 12. Proposed skill frontmatter

```yaml
---
name: investigate-markdown-corpus
description: Systematically investigate, review, and synthesize one or many Markdown documents using structure-aware navigation, iterative evidence notes, coverage tracking, conceptual revision, and targeted rereading. Use for long Markdown files, chat-thread exports, academic papers transferred from LaTeX or PDF, mixed document collections, or directories of documents where loading everything together would cause context dilution, recency bias, middle amnesia, or shallow independent summaries.
---
```

## 13. Initial acceptance criteria

Using the two supplied fixtures:

- The chat index finds five H1 headings.
- A depth-one projection yields five complete exchange units.
- The exchange units cover the source without overlap or content loss.
- The paper index finds one H1, fifteen H2s, and twenty-two H3s.
- Depth-two and depth-three outlines derive from the same complete index.
- Reading any unit reproduces the exact original source bytes.
- Equations, long lines, images, and LaTeX residue remain unchanged.
- Changing a source invalidates its prior index.
- Neither indexing nor reading modifies the source.

This is now sufficiently converged to implement as a small skill plus a narrow PowerShell utility without committing to the larger processing architecture we deliberately excluded.
