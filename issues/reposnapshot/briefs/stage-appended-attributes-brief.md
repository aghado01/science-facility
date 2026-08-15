# Stage-appended attributes — brief

**Status:** filed, not started · **Filed:** 2026-08-15 · **Track:** pre-ingestion
mechanism. Recovers a pending update that dropped out of view because it lives in
`design/admiral-orchestration.md` rather than the consolidation plan.

Sources: crawler `.TODO` bullet 3 · admiral-orchestration §"The through-line",
§"Known residues to clean" #2 · this session's binary/encoding discussion.

## What this is

From the crawler's own TODO:

> *Pipeline can append attributes after each stage to facilitate coordination and
> communication from stage to stage*

And the through-line doctrine already written:

> *Information produced at earlier stages is retained and selectively usable
> downline in the pipeline, without intervening stages needing to handle or pass
> through data they don't themselves consume.*

The mechanism is the general form of a thing the pipeline keeps needing
one-off: a stage learns something, and a **later** stage wants to route on it.
Crawler stamps identity and stat metadata today; that is the mechanism's first
instance, hardcoded. This generalizes it.

## Why it surfaced now

The binary/encoding work needs exactly this and nothing else. Working through it:

- Content-derived facts (binary-ness, source encoding) cost a read, so they must
  be produced **after** the free filters have culled the candidate list — not at
  crawl, which walks the whole tree including everything ignore is about to
  discard.
- The stage that should *decide* admission is the one named for it. Ingest
  already merges ignore's `FileTooLarge` / `ExtensionBlacklisted` into its own
  `Skipped` output, so a binary exclusion joins an existing framework rather than
  needing a new one.
- The stage that should *use* the encoding is `file-read`, downstream.

So: produced at ingest, consumed in the chain. That is a stage-appended attribute,
and building it as a bespoke `Encoding` field would be solving the general problem
badly, once.

**Worked example, and the intended first customer:**

| stage | appends | consumed by |
|---|---|---|
| crawler | `AbsolutePath` `RelativePath` `NodePath` `SizeBytes` `LastWriteUtc` | ignore (filters), file-read (reads), assemble (identity) |
| ingest | `Encoding` | file-read — decodes with a measurement instead of asserting UTF-8 |

Note what the example does **not** need: no `IsBinary` stamp. If ingest excludes
binaries, every descriptor reaching the chain is non-binary by construction. The
mechanism should make facts available, not accumulate flags.

## The contract question this must answer — residue #2

Admiral residue #2 is still open and becomes load-bearing the moment a second
stage appends:

> *Shared mutable objects across the boundary — ignore mutates crawler's
> node/file objects in place (stamping, pruning). Contracts must state ownership
> transfer or copy-on-enrich.*

Current state is better than that reads: ignore was de-stamped in Phase 1 and now
constructs new node objects, and `file-read` copy-on-enriches through `Copy-Bag`.
But `$joined.Files` still holds **references to crawler's original descriptor
objects**, so the question is live rather than fixed — it simply has no appender
exercising it yet.

**The rule has to be settled by this brief, not after it**, because appending is
the operation that makes it matter:

- **copy-on-append** (the fleet's existing posture, per `bag-helpers.ps1`) — a
  stage clones and returns; upstream objects are never touched. Consistent with
  the processor contract; costs an allocation per item per appending stage.
- **declared ownership transfer** — a stage may mutate what it was handed,
  because the contract says the handoff transfers ownership. Cheaper, and
  requires that nobody retains a reference expecting immutability — which
  admiral's retained-state design would have to honor.

Recommend copy-on-append, on the grounds that it is already what the chain does,
so the pre-chain stages would be adopting the fleet's rule rather than inventing
a second one.

## Not a prerequisite: the diagnostics split

Consolidation item 6 / residue #3 (crawler mixes diagnostics into its graph
result) is **not** blocking, and reads as more entangled than it is. Crawler
returns `@{ RootPath; Graph; DirectoryCount; FileCount; SkippedCount; Skipped }` —
the diagnostics feed is already a **sibling** of the graph, not folded into it.
Downstream stages slice the graph and never touch it. Appended attributes live on
nodes and file descriptors, which is a different axis. Item 6 stays cosmetic; it
was briefly overstated in discussion and is corrected here.

## Scope

- A stated contract for appending: who may append, what the ownership rule is,
  and how a consumer discovers whether a field is present.
- Applied to the one real customer (`Encoding` from ingest), not built
  speculatively for imagined ones.
- Residue #2 closed as part of it.

## Non-goals

- Admiral. The build-against-absent-admiral rule applies: declare the contract,
  satisfy it with the test harness playing admiral.
- The through-line question of whether information flows *through* the
  orchestrator or laterally between stages — open in admiral-orchestration Q1/4,
  and this mechanism should not pre-empt it. Appending to a descriptor that
  travels the pipeline is compatible with either answer.
- Re-litigating greedy crawl. Settled 2026-07-28: crawl everything, filter
  afterwards; the JIT coupling was rejected deliberately.
- The crawler class split (its TODO bullet 1) and the diagnostics method (bullet
  2). Independent.

## Open calls

- **Ownership rule** — copy-on-append vs declared transfer. Recommended above.
- **Whether appended attributes are typed or free-form.** The open element model
  says free-form bags with observational declaration; the descriptor identity
  contract is a fixed shape. Appended attributes sit between the two and it is
  not obvious which side they belong on.
- **Whether ingest is the right appender for `Encoding`**, or whether a distinct
  admission step should own the sniff, leaving ingest purely a dispatcher. Ties
  to the encoding brief's option (b).
