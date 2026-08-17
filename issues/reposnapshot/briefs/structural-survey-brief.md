# Structural survey element — implementation brief

**Status:** SHELVED, not urgent. Filed 2026-08-04 · Design home:
`rs.core.assemble-design.md` §"Structural survey elements" (concept, feasibility
boundary, span-anchor decision) · Registry: `v3-consolidation-plan.md` §E.

**Sequencing:** downstream of the code trunk maturing — writers, then admiral —
same shelf as the content-class dispositions. Nothing here blocks current work,
and current work does not block it. Pick it up when the writer phase gives
payloads real addresses.

## Why it exists

The retired "preview" concept meant **truncated content** — the first N bytes,
whose informativeness is an accident of what happens to sit at the top of a
file. This is its successor, and the reason the retirement was right: emit the
**shape** of a file (declarations, signatures, defaults, span anchors) instead
of a prefix of its text. Same purpose — orient a reader cheaply — without the
accident.

Motive is token economy for the reading agent (developer frame). Full content
for everything is the expensive default; a signature-level element is the cheap
index that makes selective fetch worthwhile. It is the payload-side counterpart
to the MCP wishlist's byte-span fetch: the survey tells the agent WHICH spans to
ask for.

**Noted at filing (user):** this is the first instance in the wild of
preview-adjacent functionality arriving organically — it was not designed toward,
it fell out of needing to read parameter defaults that reflection cannot see.
That provenance is worth preserving: the shape of the feature was discovered by
use, not specified up front.

## What already exists

`tools/rs.dev.signatures.psm1` — developer utility, no rs.core dependency, off
project-map's operational surface. Suite `tools/tests/rs.dev.signatures.tests.ps1`
(97 asserts).

- `Get-FunctionSignature` — three input modes (`-Path`, `-Command`,
  `-ScriptText`/`-SourceName`) sharing one AST walk, so records are identical
  apart from the source label (asserted).
- Covers all three declaration forms this codebase uses: **Script** param blocks
  (every processor is body-only with no function wrapper), **Function** incl.
  interior helpers at any nesting depth, **ClassMethod** (crawler / ignore /
  colonel are classes). A function-only walker would miss most of the tree.
- Per parameter: `DefaultText` as written and `HasDefault` separately, so `$x`
  reads differently from `$x = $null`; mandatory (both attribute forms),
  position, switch, aliases, validation attributes.
- Per declaration: `IsAdvanced`, `OutputType`, `HasDynamicParam`, comment-help
  `Synopsis`, `Line`/`Location`, and `Span` (char + byte anchors — see the
  design doc; byte offsets null when not honestly derivable).
- `Compare-ParameterSurface` — partition + same-name conflicts; carries the live
  guard that Compile-Plan / Invoke-Plan stay disjoint.
- `Format-FunctionSignature` — readable rendering.

**The `-ScriptText` mode exists specifically to make this wrappable.** A chain
item carries Content that upstream mutators have already rewritten; re-reading
the file from disk would survey the wrong bytes and silently defeat the
operation-order property below.

## The port: a wrapper, never a copy (user, 2026-08-04)

The processor **imports** the tool rather than duplicating extraction. The
mechanism already exists and is currently unused: colonel's `Build-Iss` calls
`$iss.ImportPSModule($mod)` for every entry in `IssModules`, and every
processor's self-documentation block already carries a `Required IssModules`
field sitting at `none`.

Shape of the work:

1. New processor, body-only per the colonel contract (no `#Requires`, top-level
   `param($Item, $Config)`, interior helpers permitted). Declares
   `Required IssModules: <path to rs.dev.signatures.psm1>` in its self-doc block.
2. Body: resolve the content key (`Content` else `Text`, harmonized mutator
   contract — but this step is **enrich-only**, so it must NOT rewrite content;
   position class is the read-only tail, same as rs-content_meta). Call
   `Get-FunctionSignature -ScriptText $content -SourceName $Item.RelativePath`.
   Attach one element. Pass through unenriched when there is no content key.
3. Config surface: what to extract (kinds, whether to include nested helpers,
   whether to include span anchors), so the element can be tuned lean.
4. Project a **lean** element — the dev-tool record carries fields useful at a
   console that are dead weight in a payload. Decide the projection deliberately;
   token economy is the whole point.

Assemble needs **zero changes**: the open element model collates any attached
element and declares it in `Header.Elements` without knowing it exists.
rs-content_meta is the working precedent for the shape (one namespaced element
holding a sub-structure).

## Operation-order — read-only tail, same as rs-content_meta

**Position: after ALL content mutators.** No tension with rs-content_meta'
invariant; the survey shares it, for the same reason.

(An earlier draft argued the reverse — that the survey should precede the
comment strippers to keep doc prose. User challenged it 2026-08-04 and was
right: that was a documentation concern smuggled into a structural one.
Comments are not executable code and contribute nothing to structure.)

- **Structural extraction is comment-invariant** — verified against
  `rs.core.ignore.psm1`: 33 declarations before and after rs-psstrip's default
  ops, structural records byte-identical, content 43047 → 26075 chars. Nothing
  is gained by running early.
- **Span anchors must index the bytes the payload ships.** Running before the
  mutators would anchor into pre-mutation content no reader receives — an index
  pointing at bytes nobody has. This is the binding constraint.
- **Frontmatter needs no special handling**: `#Requires` (and other languages'
  directive species — `# type:` hints, coding cookies, pragmas) are the one
  comment-shaped thing that IS structural, and rs-psstrip's ontology already
  makes FrontMatter a named never-strip kind. Read it as parsed
  `$ast.ScriptRequirements` metadata, not as comment text. Verified to survive
  stripping and still parse.

**Keep documentation out of the survey.** Prose in a survey element works against
the token economy that justifies the element — a survey is an INDEX, prose is
CONTENT, and an agent wanting the doc fetches it separately. The dev tool keeps
`Synopsis` (useful at a console); the element projection drops it.

Where the prose goes is now answered: the **comment sidecar**
(comment-ontology.md §"Stripping need not be lossy"). Stripping becomes
extraction, so doc prose is relocated and addressable rather than discarded — and
a survey record links naturally to its doc-string entry (adjacent spans), making
"give me the signature" and "give me its documentation" two lookups against one
index.

**Candidate structural addition:** `$ast.ScriptRequirements` is free from the
parse and genuinely structural (declared dependencies). The tool does not
extract it yet — worth adding when the port happens, or sooner.

## Open decisions

- **Element naming** (`Signatures`? `Survey`? `Declarations`?).
- **Fidelity field is mandatory** — `ast` vs `regex` per language. Without it a
  reader cannot distinguish "no edge exists" from "could not see edges" and will
  over-trust the summary. FallbackMode is the precedent.
- **Parse-cost sharing**: rs-psstrip already parses PS source; a naive survey
  processor parses the same file a second time. Either publish a shared parse
  artifact or fold extraction into the existing processor.
- **Per-language**: one dispatching processor vs a family. PS gets native AST;
  others start with thoughtful-regex per the language-expansion doctrine — which
  reaches tier 1 (declarations) but not tier 2's scope-accurate free variables.
- **Emission**: IR element only, or additionally a standalone writer product (a
  repo-wide signature manifest, tree-manifest analog)?
- **Disposition tier**: the survey enables a *signature-only, no content* payload
  tier between full content and the config sidecar's descriptor-only pointer.
  Whether that becomes a routing option is a writer/admiral decision.
- **Span anchor rebasing**: the tool's anchors are relative to the content it was
  handed. Once the writer assigns payload addresses, anchors need composing with
  row/shard offsets — the same reconciliation already queued for sharding's
  ByteSpan naming.

## Scope discipline

Do NOT build tier 3 (intra-procedural CFG, type inference) into the element. A
per-function basic-block graph across a repo is larger than the source it
summarizes; the survey's value is inverse to its resolution. Tier 3 belongs in
the MCP layer as an on-demand tool, invoked after tiers 1–2 have narrowed the
target. Feasibility analysis and the tiering table are in the design doc.
