# Markdown processor family — mdnav concept extraction (design seed)

**Status:** scoping · **Filed:** 2026-07-29
**Source:** `utils/skills-dev/doc-dive/mdnav` (mdnav.mjs — reader-side
structure-aware navigation over Markdown corpora; README is the design
authority). Extraction = concepts, not code (the implementation is Node;
everything needed is line-oriented byte scanning — squarely in the
language-expansion doctrine's thoughtful-regex tier, no md AST).

## The boundary, named by mdnav itself

mdnav is READER-side: it navigates unmodified sources and "makes sure an
agent never has to ingest the garbage in order to discover that it is
garbage." Its README explicitly places repair upstream — "in a processor
like tp-perplexity." This doc is that upstream transfer: the same
measurements and segmentation machinery, applied GENERATION-side as colonel
processors at ingestion time. Complementary tools, one concept set.

## The design rule transfers verbatim

> Presume about the reading process. Presume nothing about the content.

Sizes, spans, unit counts, cadence, noise census — properties of the
material *as an object* — are processor business. Relevance, topic,
attribution, reading order are the reader's (or flavor config's). This is
RS doctrine already (attributes as triage signals; assemble declares,
writers consult; reader decides); mdnav proves it at markdown granularity:
measurements like `cv=1.08` stay honest where a classification ("these
blockquotes are turns") would be confidently wrong.

## The family (three processors, descriptor contract from birth)

All three speak the **descriptor contract** (Content; open-bag
copy-on-enrich) — this family must not extend the tp-era debt (6d).

### rs-mdprofile — enrich-only tail (element: `MdProfile`)

The triage instrument. Attaches measurements, classifies nothing:

- **Construct composition**: runs per construct (paragraph/list/fence/
  blockquote/heading-by-level/break/html/table) with bytes, share; fence
  info-string histogram (`powershell×43` reads faster than any heading).
- **Cadence**: median gap + **coefficient of variation** per construct —
  the delimiter discriminator (cv < 0.6 spanning the document = something
  *dividing* it; bursts = decoration inside something else). Delimiter
  candidates reported as measurement, never applied automatically.
- **Grain signature**: unit counts at depths 1/2/3 + median unit size;
  Bytes÷H1 (delimiter vs title — bimodal on real corpora); partial-nesting
  share (% of depth-1 units containing any H2 — embedded prose structure
  vs authored hierarchy).
- **Noise census** by species (see rs-mdstrip) with bytes and worst
  offender.
- **Structural facts**: maxline (a 400 KiB line is embedded data),
  heading/break correspondence (aligned | more-h1 | more-breaks — neither
  basis privileged), frontmatter/BOM/CRLF-mixed/unclosed-fence/setext
  flags.

Consumers: the reading agent (payload element — arrives via the open
element model with zero assemble edits) AND rs-mdseg's basis selection.

### rs-mdseg — segmenting parser (the generalized threadparser core)

Basis-driven unit segmentation with mdnav's invariants:

- **Three bases, one address space**: headings@depth · thematic breaks ·
  fixed windows (for documents with neither). No format assumed.
- **Tiling invariant**: active units concatenate to the source
  byte-for-byte — PREAMBLE for content before the first heading, BODY for
  headingless documents, no content ever dropped. (mdnav checks this on
  every fixture + a 3.5 MB corpus; the port keeps the invariant as a test.)
- **Fence-aware recognition** (backtick + tilde, char and length tracked):
  `# comment` inside a code block is not a heading — naive grep reported
  38 H1s where there are 22 on real material.
- **Runs break on blank lines**: merging adjacent blockquotes across a
  blank line hid a substantive turn in a real dive. Discipline, not detail.
- **Windows split only on newlines**; an unbreakable run is emitted as one
  window flagged UNBROKEN (slicing non-prose at arbitrary offsets
  manufactures meaningless fragments).
- **Extent**: unit | subtree (partition cell vs whole branch).
- Output: `Units[]` with **half-open byte spans into the processed
  Content** — which makes rs-mdseg the SUBADDRESSING substrate (the
  audit's "extent linearization → composite chunks" track; mdnav's
  `Dnnn:Hnnnn[@digest]` → span model is working prior art, including
  drift detection via the digest).

Basis selection is config (operation-order doctrine: config selects,
implementation owns mechanics); `MdProfile`'s delimiter candidate *informs*
the selection — explicitly, never silently (coherence doctrine).

### rs-mdstrip — content mutator (noise elision, addressed)

The ontology's conceptual `rs-mdstrip` made concrete with mdnav's species
taxonomy — detection by shape, never by content:

| species | remedy | default |
|---|---|---|
| `data-uri` (embedded file) | whole `![](…)` wrapper goes — no debris | strip |
| `html` (tags/comments) | tags go, **inner text preserved** — prose is never deleted | strip |
| `signed-url` (presigned links — signing params are definitional, zero false positives) | `![](signed)` goes entirely; `[label](signed)` keeps its label — the citation's name survives the dead URL | strip |
| `image-ref` (external `![alt](https…)`) | costs a URL, records a figure existed | keep (opt-in) |
| custom | `--strip-match` analog: caller-supplied pattern through the same machinery | opt-in |

- **Elisions are addressed, not hidden**: >1 KiB leaves a marker comment
  with the span (`elided image 404.79 KiB @14187..430301`) — re-readable
  without the strip. Elided spans are recorded (ledger semantics) so
  SpanBytes/coverage arithmetic stays honest.
- Embedding vs referencing differ by four orders of magnitude (1.2 MB vs
  125 B on the sample corpus); only embedding is a context hazard, so only
  embedding strips by default. The `!` decides the remedy; the TARGET
  decides signed-ness (a 198-char GitHub permalink is signal — length
  heuristics would eat it).
- Ontology alignment: species are KINDS with per-kind default policy —
  same shape as the comment ontology, one format over.

## Disposition tiers — demote-to-sidecar (user, 2026-07-29)

The user's divergence from mdnav's treatment: some material is neither
primary content nor noise. Canonical case: **citation sections at the end
of a Perplexity reply** — content, technically relevant, but *secondary* to
the prose that cites them; the prose is what gets read, and the questions
under investigation usually live there. The full disposition vocabulary:

| tier | disposition | artifact | recovery |
|---|---|---|---|
| primary | payload | the entry Content | in context |
| **secondary** | **demote to sidecar; POINTER remains in prose** | organized, addressable sidecar entry | reviewed at will — never in context by default |
| noise | strip (addressed elision) | elision marker into source bytes | re-read without strip |
| failed/empty | diagnostics sidecar | routing record | audit |

The distinction from elision matters: an elision marker says "garbage was
here"; a sidecar entry has an *identity* — listable, scannable,
cross-referencable without re-reading source. And the pointer is not
scaffolding — **the inline citation anchors are structurally part of the
prose** (tp-perplexity already classifies inline cite clusters as content,
not metadata). The reading experience is exactly the telescope: prose in
context → anchor → sidecar entry on demand → external reference if the
investigation merits that level of detail. This is the ad-libitum
bite-geometry doctrine applied to relevance instead of length.

Mechanism — every piece already exists:
1. **Lift** (chain-side): the masking-type machinery tp-perplexity uses for
   citation footers, generalized — footer/reference sections extracted from
   Content, inline anchors preserved in place.
2. **Travel** (element): lifted material rides the entry as an element
   (e.g. `Citations`) through the open element model — declared in
   Header.Elements, zero assemble changes.
3. **Route** (emission-side): writers send the element to a sidecar
   artifact and the pointer convention into the payload — compute-vs-emit,
   with the diagnostics-sidecar precedent extended from audit trail to
   reference tier.

Consequences for the family:
- rs-mdstrip's species table generalizes to a **three-way disposition
  column** — keep | demote | strip — per species, defaults overridable
  (configurability doctrine: conventional md ingestion may default
  citation-like sections to demote; always subject to one-off overrides).
  The signed-url label-keeping rule is already a micro-demotion (label =
  pointer, dead URL = dropped) — the continuity is not accidental.
- tp-perplexity's Citations[] gains its final destination: not payload
  ballast, a sidecar with prose anchors pointing in.
- mdnav (reader-side) is slated for the same improvement in the user's
  hands — extraction-to-sidecar as run artifacts rather than
  elide-or-ingest; the shared tier vocabulary keeps both sides aligned.

Open: sidecar addressing scheme (entry key = RelativePath + anchor id?
byte-span addressable like everything else?); one sidecar per corpus vs per
document; pointer syntax in rendered payloads (the existing `[^n]` anchors
may simply suffice for the citation case).

## tp-{flavor} refactor implied — the canonical exchange envelope (user, 2026-07-29)

The target is a **surjection: variable chat-thread sources → one canonical
"exchange envelope."** Each shard payload row is a bag over a canonical
core plus optional elements:

```
ExchangeEnvelope = @{ Index; Prompt; Reply;           # canonical core
                      Citations?; ToolUse?; ... }     # optional elements,
                                                      # present when the
                                                      # flavor carries them
```

This is the open element model at exchange-row granularity: flavor lifters
are the surjection's legs — each populates what its source structurally
carries; absent capabilities are absent fields (never empty placeholders —
lean doctrine); no flavor's native structure leaks into the canonical
shape. Readers and writers speak ONE row schema regardless of source
(configurability doctrine: the header declares which elements this corpus's
rows carry). The four-tier disposition then applies WITHIN the envelope:
Prompt/Reply primary; Citations secondary (sidecar + prose anchors);
noise stripped; ToolUse disposition per-corpus config (primary for
tool-trajectory investigations, secondary otherwise).

Decomposition: tp-perplexity becomes **rs-mdseg (breaks basis) + Perplexity
lifter** (citation footers → Citations[], H1 → Prompt, sentinel masking
retained). The segmentation core is shared and measured-basis-capable;
flavor processors shrink to their genuinely flavor-specific lifting. New
flavors (claude/chatgpt/gemini — thread-corpus open decision 4) start from
`profile` output instead of reverse-engineering each export format, and
their lifters target the same envelope. Thread-corpus open decision 3
(long-reply secondary chunking) gets its mechanism for free: windows basis
+ UNBROKEN flags.

## Open decisions

1. Unit representation: `Units[]` element on the item (thread adapter
   explodes later) vs exploding in the processor — interacts with
   assemble's Thread adapter contract (envelope → N).
2. Profile→basis wiring: config-explicit always, with MdProfile as advisory
   measurement (leaning — explicitness doctrine), vs an opt-in
   `Basis='Measured'` mode.
3. Port scope ordering: mdprofile first (pure enrichment, immediate payload
   value) → mdseg (unblocks flavor refactor + subaddressing) → mdstrip
   (needs the elision-marker/ledger conventions settled with writers).
4. Naming (rs-mdprofile / rs-mdseg / rs-mdstrip are working titles).

## Cross-references

- `utils/skills-dev/doc-dive/mdnav/README.md` — design authority for the
  concepts; acceptance fixtures enumerate the edge cases the port must keep
  (CRLF, multibyte, fenced heading-like text, preamble, headingless, no-H1,
  setext, chat-shape deviations).
- `issues/thread-corpus-container.md` — decisions 3/4; the ExchangeBlock
  unit model rs-mdseg's units feed.
- `issues/v3/comment-ontology.md` — kinds/policy pattern rs-mdstrip
  instantiates for markdown noise.
- `issues/v3/lts-v3-transfer-audit.md` — subaddressing note (mdnav address
  model as prior art).
- TODO.md "more general markdown processing and specialized
  segmentation/sharding mode" — this is that design.

## Work log

_(append findings/results here)_
