# mdnav

Structure-aware navigation over Markdown corpora. Zero dependencies, one file,
Node ≥ 18. Exposes structure and literal source spans; decides nothing about
meaning.

```bash
node mdnav.mjs discover ./docs --recursive
```

## Design rule

> **Presume about the reading process. Presume nothing about the content.**

Sizes, byte spans, unit counts, spine ratio, structural anomalies and coverage
arithmetic are properties of the material *as an object* and are all fair game.
Relevance, topic, importance and reading order are the reader's job and are never
computed here. That line is what keeps the tool useful without it quietly making
the decisions the reader is there to make.

## Address model

Every anchor is `Dnnn:Hnnnn[@digest]` resolving to a half-open byte span
`[start, end)`. Planning, reading, coverage, provenance and batch re-reading all
speak those same coordinates, so a set of anchors *is* a set of spans *is* a
re-readable batch — no translation layer anywhere.

Three orthogonal knobs:

- **Basis** — what delimits a unit. Headings (`Hnnnn`, the default), thematic
  breaks (`--by breaks`, `Snnnn`), or fixed windows (`--windows`, `Wnnnn`) for
  documents with neither. **No document format is assumed.** A Markdown file is
  not presumed to be a chat envelope, a manuscript, or anything else; which basis
  yields meaningful units depends on how the document was produced, and that is
  the reader's call. All three bases share one address space and one coverage
  ledger.
- **`--depth 1..6` chooses the partition** within the heading basis. Headings at
  or above the depth are *active* and their units tile the document exactly.
  Headings below it remain literal content inside the enclosing unit.
- **`--extent unit|subtree` chooses what you take.** `unit` is one cell of that
  partition. `subtree` is the whole branch under a heading, independent of depth.

The invariant, checked on every fixture and on a 3.5 MB real corpus: **the units
active at any depth concatenate to the source byte-for-byte.** Nothing is dropped
because a document lacks the structure you expected — content before the first
heading becomes `PREAMBLE`, a headingless document becomes one `BODY` unit, and a
document whose first heading sits below the chosen depth still partitions.

The `@digest` suffix is four hex characters of the heading text. Anchors are
ordinal, so an edit upstream shifts them; the digest turns a silently-wrong
resolution into a warning on stderr.

## Verbs

| | |
|---|---|
| `discover <path>... [--glob '*.md'] [--recursive]` | Walk, dedupe, assign ids, index, print inventory |
| `index <file\|Dnnn>... [--refresh]` | Index or re-index specific documents |
| `outline <ref> [--depth N \| --by breaks] [--within <a>] [--preview N] [--truncate N]` | List units with unit/subtree sizes |
| `outline <ref> --windows <bytes> [--within <a>]` | Fallback partition for documents with no usable delimiter |
| `read <ref> --heading <a> \| --from <a> --to <b> \| --headings <a,b,c> [--strip all] [--strip-match <re>]` | Materialize literal source bytes |
| `coverage [<ref>...] [--depth N] [--by breaks]` | Bytes read vs. total, unread and partial anchors |
| `locate <pattern> [<ref>...] [-i] [--depth N] [--max N]` | Anchors and line hits, never content blocks |
| `profile [<ref>...]` | Construct composition and cadence for an unknown document |
| `marks <ref> --kind <construct> [--preview N] [--min bytes]` | Enumerate occurrences of any construct, as runs with spans |

Common flags: `--work-dir <path>` (or `$MDNAV_WORK_DIR`), `--run <stamp>`.
See [Runtime artifacts](#runtime-artifacts).

### Reading at grain

`--heading` takes one unit. `--from/--to` merges a contiguous run into one span —
for an idea that develops across several consecutive units. `--headings a,b,c`
returns several discontiguous spans as one packet, which is how you re-read every
anchor supporting a single concept in one call instead of hunting for them.

### Coverage is measured in bytes

Unit counts are not comparable across a change of grain — four units read at depth
2 is not four of twelve at depth 3, and neither is comparable to segments or
windows. So byte spans are the invariant measure, every read is stamped in the
ledger with the basis and depth that produced it, and every unread listing states
the grain it was computed at. Overlapping reads are merged, so a subtree read
subsumes its units rather than double-counting.

## Runtime artifacts

Runs are **local to the corpus and invisible to it**:

```
<corpus>/.doc-dive/<UTC yyyyMMdd_HHmmss>/
                   ├── inventory.json
                   ├── documents/Dnnn.index.json
                   └── reads.jsonl
<corpus>/.doc-dive/LATEST          → the stamp of the most recent run
```

Locality is the point — artifacts belong beside the documents they describe,
because that is where you will look for them. Scattering loose files into the
source directory is the failure; *adjacency* is not. The dot prefix is what
separates the two: `discover` skips dot entries, so a later scan can never index
the reader's own exhaust as source material. mdnav **refuses** a work dir placed
inside the corpus where `discover` could see it.

Resolution order, most specific first:

1. `--work-dir <path>` — an explicit anchor
2. `$MDNAV_WORK_DIR` — the same, without repeating the flag
3. `<corpus>/.doc-dive/` — the corpus anchor, taken from the first target;
   when documents are spread across the filesystem, the **first** one anchors

Anchor explicitly when the corpus is curated and should not be touched at all — a
reference library, a bibliography, an issues folder. Pointing the run at a
project's own `.claude/` directory keeps the runtime artifacts with the *work*
rather than with the *sources*:

```bash
node mdnav.mjs discover ./bibliotheca --work-dir ../thermomapper/.claude/doc-dive
```

If the corpus location cannot be written to, mdnav says so and names the
override rather than relocating silently — where artifacts land is the caller's
decision, not the tool's.

Every run is a **new stamp**; nothing is overwritten, and earlier runs survive for
comparison. Stamps are second-resolution, so runs started in the same second get a
deterministic `-2`, `-3` suffix rather than silently merging. Later verbs follow
the most recent run, so the path is never retyped mid-investigation. Everything
under the run directory is reproducible and disposable — delete it to start over.

## Output discipline

`read` writes literal source bytes to stdout, and a single-anchor read is
completely undecorated. Multi-span packets get one `<!-- mdnav Dnnn:Hnnnn -->`
marker per span. Everything diagnostic — sizes, warnings, staleness, mismatches —
goes to stderr. There is deliberately no `--out`: writing a file the reader then
has to open doubles the call count and defeats the point.

## Profiling an unknown document

```bash
node mdnav.mjs profile D001
```

Given a Markdown file you know nothing about, no construct can be assumed to
carry the structure. Headings may be titles or delimiters. Blockquotes may be
turns or pull-quotes. A `<details>` block may be a tool call or an aside. So
`profile` measures **composition and cadence** and reports both, leaving
recognition to the reader:

```
  construct      runs      bytes      %   median gap      cv   detail
  paragraph      406     34,603   32.0%        187 B    0.99
  list            92     26,798   24.8%        857 B    0.81
  fence          119     22,846   21.1%        464 B    1.37   text×47 powershell×43 json×13
  blockquote      36     16,078   14.9%     1.23 KiB    1.08
  heading h2      82      2,668    2.5%        918 B    0.77
  heading h3      58      1,512    1.4%        486 B    1.78
```

**`cv` is the discriminator** — the coefficient of variation of the gaps between
occurrences. A construct recurring at even intervals across the whole document is
*dividing* it; one appearing in bursts is decoration inside something else. Both
are byte-level facts, so this stays a measurement rather than a classification.
Constructs with `cv < 0.6` spanning most of the document are named on stderr as
delimiter candidates; paragraphs are excluded, being filler by nature.

Measured on real material, it picks the delimiter every time — including the
cases where it is not what you would guess:

| document | flagged | reality |
|---|---|---|
| 62 H1s, `cv=0.59` | `heading h1`, `break` | H1 delimits turns, `---` separates them |
| 14 H1s, `cv=0.35` | `heading h1` | flat H1 records |
| 0 H1, 0 H2, 37 H3 | `heading h3` | structure demoted upstream; H3 is the unit |
| no headings at all | *(nothing)* | correct — use `--by breaks` or `--windows` |

And it is honest about ambiguity. In one design transcript, blockquotes are 14.9 %
of bytes but score `cv=1.08` and are **not** flagged — correctly, because that
document uses blockquotes for two different things (user turns *and* the model's
own pull-quotes). A tool that had labelled them "turns" would have been
confidently wrong; one that reports `1.08` is simply right.

The `detail` column histograms fence info strings, which is often the fastest
read on what a transcript was *about* — `powershell×43` says more about a working
session than any heading will.

### Telescoping: what each unit is made of

`profile` characterises the document; `outline --comp` characterises each **unit**,
so you can decide whether to open one without opening it:

```
[H0001] H1  unit=2.45 KiB    [quote84 prose12]        Design stateful markdown synthesis
[H0006] H1  unit=406.72 KiB  [data100]                can i get a quick double check…
[H0013] H1  unit=6.44 KiB    [code70 prose13 list11]  observability is a first class…
[H0019] H1  unit=2.01 KiB    [prose32 tbl22 list20]   so these are the droids i'm…
```

Top three constructs by share, ≥5 % each. Noise keeps its own species — `data`
for an embedded file, `html` for markup, `link` for a presigned URL, `img` for an
external reference — because they are all "not prose" but only one of them is a
context hazard. Crucially, noise bytes are **reassigned out of** whatever
construct contains them: an embedded PNG sits inside a paragraph line, and
reporting that unit as `prose100` would be exactly backwards.

The three-step telescope on a document you know nothing about:

```bash
node mdnav.mjs profile D001                      # what is this made of, and what divides it
node mdnav.mjs outline D001 --depth 2 --comp     # which units are worth opening
node mdnav.mjs read D001 --headings H0042,H0053  # open only those
```

When `profile` flags a candidate that is not a heading, `marks` is the bridge —
`outline` enumerates headings, `marks` enumerates *any* construct, as runs rather
than lines, each with a byte span so it can be read directly:

```
      40..1724     1.64 KiB   1L  D001:H0001   if i wanted to design a skill and perhaps…
    1776..2080        304 B   1L  D001:H0001   I'm using the skill-creator guidance because…
   13600..14764    1.14 KiB   1L  D001:H0017   its important to keep in mind what jso-jackson…
   14816..15143       327 B   1L  D001:H0017   You're right: `jso-jackson` is informative as…
```

Read any of them with `read <ref> --span <start>..<end>` — raw byte spans are the
substrate everything else is built on, so they address anything a run can cover.

The alternation above (a large run, then a ~320 B one that opens the same way
every time) is a **structural motif**. mdnav shows it and says nothing about it.
Deciding that the large runs are one speaker and the small ones another is a
reading judgment, and it stays with the reader — a prior on likely attributions
belongs in skill prose, where being wrong costs an assumption rather than
corrupting a measurement.

Runs break on blank lines. That matters more than it sounds: merging two adjacent
blockquotes across a blank line hides whichever follows behind whichever preceded
it, and an ad-hoc script that got this wrong lost a substantive turn in a real
dive.

`[quote84 prose12]` on the first unit of that example says the document opens with
an 84 %-blockquote block — the turn envelope — in one call, before a byte of it is
read.

## Grain signatures

`discover` and `index` report a `Grain` column: **unit counts at depths 1/2/3,
then the median unit size at the shallowest depth that divides anything.** It is
the fact that decides where to start reading, and it is not derivable from heading
counts alone.

These are measurements, not classifications — mdnav never labels a document. But
the shapes recur, and recognising them is most of triage:

| signature | what you are looking at |
|---|---|
| `62/219/221~3.29K` | Many depth-1 units of a few KB each. Level-1 headings delimit records — turns in a transcript. Start at depth 1. |
| `1/83/141~918B` | One unit at depth 1: the H1 is a **title**, not a delimiter. The document's own structure begins at H2. |
| `1/1/38~746B` | Structure lives deeper still. Something upstream flattened or demoted the headings. |
| `1/1/1~6.57K` | No usable headings at any depth. Try `--by breaks`, else `--windows`. |
| `15/15/15~1.14K` | Flat records with no nesting. Depth is irrelevant; read them as they are. |

Two derived readings worth knowing:

**`Bytes ÷ H1` separates a delimiter from a title.** Three to five KB per H1 is a
conversational turn. A whole document under one H1 is a title. In the sample
corpus the split is bimodal with nothing in between — documents yield either 1
depth-1 unit or 36–62 of them.

**Partial nesting is the signature of embedded prose structure.** Where H1
delimits turns, only 55–75 % of those units contain any H2 — because sub-headings
come from whatever the replies happened to contain. A document whose single H1
contains 100 % of its H2s is a hierarchy the author built. You do not have to be
told which is which; the distribution says it.

That distinction does not change the partition — headings are headings — but it
changes what descent *gives* you. A paper's H2s are the author's peers and can be
read independently. The H2s inside one transcript turn are one continuous
argument, so descending there favours `--extent subtree` or a `--from/--to` merge
over reading the sub-headings as separate units.

`outline` reports the same shape for whatever partition you chose: unit count,
total, **median and largest**. A partition of 62 even units and one where two
units hold 92 % of the bytes need completely different plans.

## What it reports rather than guesses

- **Heading/break correspondence.** Two independent structural facts: the level-1
  heading count and the thematic-break count. Whether they *should* correspond is
  a hypothesis about the document's provenance, so the counts and their relation
  (`aligned`, `more-h1`, `more-breaks`) are reported and neither basis is
  privileged. In a sample of 33 real exports, 25 disagree — and for several of
  them (0 H1s, 8 breaks) the break basis is simply the correct one.
- **`maxline`** — the longest single line, shown when a unit isn't already flagged
  as noise. Prose has line breaks; a 400 KiB line is embedded data, and knowing
  that before diving is worth more than any content-level heuristic.
- **Spine ratio** — bytes occupied by level-1 heading lines. Where the H1 line is
  the complete user turn, this measures what the intent trajectory costs to read.
  Observed range on real material: 0.4 % to 21.8 %.
- **Setext suspects** — underlined headings aren't parsed, but a document
  containing them is flagged rather than given a misleading outline.
- **Frontmatter, BOM, CRLF/LF/mixed, unclosed fences.**

## Triage: keeping garbage out of context

Some documents are mostly machine furniture. In the sample corpus one 876 KB
transcript is **91.6 % embedded PNG** — its 406 KiB "exchange" is a 2 KB exchange
plus a screenshot, so reading it raw costs ~104k tokens to deliver ~500 tokens of
content. Across all 33 documents, 34.2 % of bytes are noise, almost all of it
four embedded images.

Detection is by shape alone, so it presumes nothing about content:

| kind | what it matches | in `--strip all` |
|---|---|---|
| `data-uri` | An **embedded file** — `data:<type>;base64,<payload>`. The whole `![](…)` wrapper goes when the target is a data URI, so no `![]()` debris is left. | yes |
| `html` | Tags and comments. **Inner text is preserved** — `<div align="center">⁂</div>` leaves `⁂`. Prose is never deleted. | yes |
| `signed-url` | A **presigned object-store link** — `X-Amz-Signature`, `X-Amz-Credential`, `X-Goog-Signature`, an Azure `sig=`. Dead by construction once expired. | yes |
| `image-ref` | A **reference to an external image**, `![alt](https://…)`. Costs a URL, and records that a figure was there. | no — opt-in |

Embedding and referencing render identically but differ by four orders of
magnitude: in this corpus, 4 embedded files total 1,197,588 B against 1 external
reference at 125 B. Only the first is a threat, so only the first is stripped by
default.

Presigned links share the `[]()` / `![]()` shape with ordinary citations, so the
**target** decides, never the URL length — a 198-character GitHub permalink is
signal, and a length heuristic would eat it. Signing parameters are definitional,
so there are no false positives: across the 33 documents here, with 246 GitHub
URLs and 110 markdown links, the filter fires zero times.

The `!` then decides the remedy. `![](signed)` has nothing worth keeping and goes
entirely; `[threadparser-notes.md](signed)` keeps its **label**, because the name
of what was cited survives the URL that no longer resolves.

For a species mdnav has no pattern for at all — tracking pixels, whatever a given
corpus carries — `--strip-match '<regex>'` aims the same elision machinery, with
the same placeholders and ledger accounting, at a pattern you supply.

This surfaces at three points, so triage happens before the cost is paid:

- **`discover`/`index`** report each species separately —
  `embedded=783.11 KiB(92%)`, `html=1.65 KiB`, `imgref=1` — and name
  the worst offender with a recommendation to strip or preprocess.
- **`outline`** flags each unit: `noise=404.81 KiB(100%)` next to its size, so a
  unit that is entirely a screenshot is visible without being read.
- **`read`** warns on stderr *before* writing when a span carries >64 KiB of it —
  once bytes reach stdout they are in context and the cost is already paid.

### `--strip` elides at read time; the source is never touched

```bash
node mdnav.mjs read D032 --heading H0006 --depth 1 --strip all   # 416,483 B → 2,016 B
```

Elisions are **addressed, not hidden**: anything over 1 KiB leaves
`<!-- mdnav: elided image 404.79 KiB @14187..430301 -->`, so the reader can see
what was skipped and re-read the same anchor without `--strip` to get it. The
ledger records the elided *spans*, and `coverage` subtracts them — so a unit that
is 99.5 % screenshot reports the ~2 KB you actually read, not the 406 KiB you
materialised:

```
D032   1,954 / 876,280 B   0.2%  reads=1  grain={d1:1}  elided=404.81 KiB
``` `--strip` is the one place byte fidelity is
deliberately traded away, and it is always opt-in.

Repairing the document itself is out of scope — that belongs upstream, in a
processor like `tp-perplexity`. mdnav's job is to make sure an agent never has to
ingest the garbage in order to discover that it is garbage.

### Windowing splits only on newlines

Every window boundary falls after a line break. Any prose document has line
breaks, so a stretch without one is not prose — slicing it at an arbitrary offset
would manufacture fragments that mean nothing. Such a run is emitted as one
window and flagged `UNBROKEN`, which tells the reader to skip it. Windowing then
continues past it rather than running to EOF.

Heading recognition is fence-aware (backtick and tilde, opening char and length
tracked), so `# comment` inside a code block is not a heading. This matters more
than it sounds: a naive `grep '^# '` over one 876 KB transcript in the sample
corpus reports 38 H1s where there are 22.

## Sidecar layout

```
.doc-dive/current/
├── inventory.json              id ↔ path
├── documents/D001.index.json   metadata + headings + windows, no source body
└── reads.jsonl                 append-only materialization ledger
```

Everything under the work dir is reproducible and disposable; sources are never
modified. Delete the directory to start over.

## Tests

```bash
node test/acceptance.mjs
```

Self-contained — fixtures are generated into a temp directory covering CRLF,
multibyte, fenced heading-like text, LaTeX and image residue, long lines,
preamble, headingless, no-H1, setext, and both chat-shape deviations. Set
`MDNAV_KEEP=1` to keep the fixtures for inspection.
