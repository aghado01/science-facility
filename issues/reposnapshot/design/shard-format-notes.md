# Custom shard row format — observed design elements (name pending)

**Status:** description of current LTS output · **Filed:** 2026-07-22

The LTS sharded snapshot payload is not JSON/JSONL — it is a custom line-oriented
record format, a deliberate hybrid of CSV, JSONL, and length-prefixed (LPAC-style)
containers, optimized for LLM/agent consumption.

## Row grammar

> **This section is an LTS specimen, not the v3 wire.** Recorded as observed on
> 2026-07-22 and left verbatim — it is evidence. v3's wire is declared in
> `reposnapshot-v3/contracts/container.spec.jsonc` and explained in
> [shard-container-brief](../briefs/shard-container-brief.md) §The item model;
> it has since diverged deliberately in every visible respect: `idx` → `gidx`
> (zero-padded), `length` → `content_bytes`, `attributes` → `content_meta` with
> `[ … ]` not `{ … }`, `name<type>` → `name: type`, no trailing `|` (ledger
> #45), and rows built as space-joined item lists rather than delimiter-padded
> fields (ledger #49). **What carries forward unchanged is the doctrine**, not
> the syntax: header row as the schema, positional value-only rows, the nested
> block repeating no keys, and the length prefix framing the content span.
>
> The one section of this document that IS a v3 spec is
> [§Content codec — SPEC](#content-codec--spec-user-2026-08-14-supersedes-the-2026-08-09-litigation-below);
> everything above it describes LTS and everything below §Escape regime is
> superseded litigation kept as evidence.

Full form (snapshot `reposnapshot_20260723_035834`, header row enabled):

```
idx<int> | path<str> | attributes:{char_count<int> word_count<int> whitespace_ratio<float> entropy<float>} | length<int> | content<str> |
0 | .gitattributes | {594 69 0.1414 4.6930} | 613 | # Default: text fi…
```

- **Header row = the schema, CSV-style**: field names + types declared once per shard;
  data rows carry values only — self-documenting and non-redundant. The nested
  attributes block is *positional values in braces*, so even nested metadata repeats
  no keys. Tree `row_offset` values account for the header (first row starts after it).
- **Attributes block is OFF by default — deliberately.** When irrelevant, per-row
  metadata isn't neutral: read into context it wastes tokens AND inherently interferes —
  fragmenting the reader's attention between every row's content. Same doctrine as
  comment stripping, one layer down: the lean row is the default; attributes are
  opt-in when a use case values the triage signals (char/word counts, whitespace
  ratio, entropy — rank/skip rows before fetching). Disabling omits the column
  **end-to-end**: the header column AND the corresponding segment of every data row —
  the payload simply doesn't carry the data. Header and rows always agree; the schema
  line describes exactly what each row contains.
- Reduced form (attributes+header excluded, 195015 selfie):
  `<idx> | <relpath> | <length> | <content>`.
- Shard filenames may carry a grouping suffix (`_s003_reposnapshot-v3.txt` under
  ByRootDirectory grouping).

**Row termination — to confirm in spec:** design statement says rows are delimited by
a comma + rendered/ambient newline with the final row uncommaed (JSON-array-style row
discipline). Observed emissions differ: 035834 shards separate rows by ambient newline
alone (tree offsets confirm: content_end + 1 = `\n`, next row immediately); the 195015
selfie carried a trailing ` |` row terminator instead. Likely resolution: comma
discipline belongs to the JSON-side intermediate/store layout (line-per-entry compact
JSON array), ambient newline to the rendered .txt view — confirm and fix one emission
as normative when the format is named.

## Design elements

- **CSV element without quoting**: ` | ` delimiters are safe by construction — `|` is
  filesystem-invalid on Windows (path field never needs escaping), idx/length are
  numeric, and content is the final field with a declared length, so delimiter
  collisions inside content are unambiguous.
- **JSONL element without JSON**: one record per line; content unquoted, no braces,
  no keys — directly readable by a model, no parser needed, no per-row key repetition
  (token economy). JSON *compaction* is used internally as a preparation step for the
  serialized content blocks (`Get-EntryByteOffsets` matches the `"content":"…"` span),
  but the emitted encoding is a design choice, not serialization residue — see
  selective encoding below.
  **v3 divergence (user, 2026-08-09): the compaction step does not carry forward.**
  That internal `ConvertTo-Json` hop is an LTS implementation detail; the v3 custom
  container's serializer authors its escaping directly. The JSONL writer gets
  escaping from its own serialization, and the two paths stay uncrossed — so v3's
  emitted encoding is not merely "a design choice, not residue," it has no JSON
  anywhere behind it.
- **Selective encoding (deliberate feature)**: certain characters are intentionally
  encoded — notably newlines as `\n` — so line breaks are *explicit and consistent* in
  serialized code (reader clarity) and each record stays on one line. This is to keep,
  not to shed. Overall escape bloat is much reduced relative to the full JSON/JSONL
  escape regime the format replaced — reduced, not zero.
  **The regime is undeclared** — the tree manifest publishes offsets but never says
  what codec the span is in, nor what character encoding it decodes as. Framing is
  guaranteed by the length prefix; decoding is left to the reader's inference, and
  with no JSON behind the format (see v3 divergence above) there is no external spec
  to infer *from*. Filed as declarations owed: `issues/reposnapshot/planning/payload-manifest-ledger.md`
  #16 (codec) and #17 (encoding).
  **Answered for v3 by §"Content codec — SPEC"** (2026-08-14): the regime is four
  rules, declared in the tree's Compaction notice. Note the *reduced* form of the
  obligation — the notice exists so a reader does not mistake the payload for
  byte-faithful, not so a reader can decode it. Nothing decodes.
- **Length-prefix (LPAC) element — the framing authority**: field 3 = exact UTF-8 byte
  length of the content span. Pipe delimiting is presentation; it is the length prefix
  that makes the reading frame unambiguous — which is what frees the format from
  JSON/JSONL-style escape overhead as a *parsing* requirement. Framing never depends
  on encoding: with the frame guaranteed by length, encoding decisions serve the
  READER, not the parser (see selective encoding). Also: integrity check +
  manifest-free forward scan.
- **Virtual-DB addressing**: the `*_tree.md` manifest carries per-row
  `row_offset / row_meta_end / row_content_begin / row_content_end` (UTF-8
  byte-accurate) — dual addressing of whole row and content-only span.
- **Global sequential idx across shards** — corpus-wide reading order (same idx
  philosophy as the planned subaddress scheme).
- **`.txt` extension by design**: recognized extensions (.json/.jsonl/.csv) trigger
  RTE format handling in web-chat runtimes (Perplexity, DeepSeek, Gemini …) — parsing,
  tabularizing, truncation — which would destroy the seek contract. `.txt` guarantees
  raw-text treatment and steers agents to low-level reads (stated in the tree's
  Instructions block).

## Content codec — SPEC (user, 2026-08-14; supersedes the 2026-08-09 litigation below)

The v3 serializer authors this itself (no `ConvertTo-Json` hop — see v3 divergence
above), so every guarantee has to be written deliberately.

### Posture — three changes that collapse the problem

1. **No MCP on v3.** The agent-facing tooling becomes a separate successor
   implementation (Node); the PowerShell tool stays CLI. So the "MCP is the only
   real decoder" rider (`mcp-surface.md`) never materializes, and **codec
   totality has no consumer, present or planned.**
2. **Round-trip is an ideal that guides ingestion, not a property of the
   artifact.** The imperative is *don't break code on the way in*. Snapshots are
   one-way views regenerated on demand — not a currency for rehydrating source.
3. Therefore the codec **may be lossy, and should be**, wherever loss buys
   legibility or simplicity.

Finishing v3 still means working these nuances out properly: the port to another
language inherits whatever is settled here, and every exotic decision is one more
thing to re-derive.

### The rules

1. **Every line terminator becomes `\n`** — LF, CRLF, CR, NEL U+0085, LS U+2028,
   PS U+2029, VT U+000B, FF U+000C. One marker; the kind is *not* preserved.
2. **`\` is never doubled.** Literal backslashes pass through verbatim.
3. **Remaining C0 controls and DEL are stripped.**
4. **TAB stays literal.**

### Why rule 2 is the important one

The litigation below identified the invariant separating backslash from
substitution: *substitution never rewrites a character of the source — it only
adds marks where line breaks were; backslash escaping alters existing
characters.* That was the strongest argument against `\`.

Dropping the self-escape dissolves it. `\` now also only adds marks at line
breaks, so `"C:\Users\me"` renders as itself instead of `"C:\\Users\\me"`. **The
payload gets substitution's defining virtue at ~1 token instead of 3.**

The cost is decodability at the ambiguous sites: a literal backslash-n in source
is indistinguishable from an encoded line break. Measured on the production C#
payload that is the `\\` row — **127 sites across 70 shards, ~1.8 per shard,
0.22% of escapes.** And most literal `\n` in source sits inside string literals
where it already *means* a newline, so a reader resolving it as a break is
usually right; the genuinely wrong reading is Windows paths, and it is rare.
Under a no-rehydration posture, showing the source verbatim beats reversibility.

### Stage ownership — line breaks are the container's job

The serializer encodes line breaks **unconditionally**, and this is not a
violation of "the serializer does not perform compaction a content processor
already owns." Different jobs, same character: `format-ws`'s `lf` op normalizes
CRLF *within content*; the container must encode whatever line breaks *remain*,
because a raw newline breaks the one-record-per-line invariant. Delegating it
would mean a profile without `lf` emits a broken artifact.

Indentation (`rs-indent`) and inner-whitespace shape (`format-ws`) stay upstream,
per that rule.

**Lane split (user, 2026-08-14).** `format-ws` and `rs-indent` are **code-lane**
processors, and the inclination is to make them **enforced rather than optional**
on that lane — with the config surface still exposing *which* operations run. The
document-ingestion lane gets its own markdown-safe whitespace processor and its
own default chain, rather than these two accruing prose caveats. Markdown
semantics (two-trailing-space breaks, fence integrity) therefore stay out of the
code-side processors entirely.

This does not soften rule 1. Enforced *placement* does not make the op list
unsubsettable — a caller can still drop `lf` — so the serializer still cannot
assume any content-stage op ran, which is exactly why line-break encoding is
unconditional.

### Compaction is now a notice, not a cipher key

It no longer teaches a reader to decode, because nothing decodes. It states what
was done, so nobody mistakes the payload for byte-faithful:

```
## Compaction

Line breaks are normalized to LF and encoded as `\n`. Control characters are
stripped. Tabs and backslashes are literal. Content is a faithful view of the
source but is not byte-reconstructable from this payload.
```

Still sited in the tree file ahead of the Tree block (`rs.core.manifest.psm1`),
for the same structural reason as before: the tree is the exclusive entrypoint
and is read first.

### Retired by this revision

- **Totality** (old requirement 2) — no consumer, present or planned.
- **The self-escape obligation** (old requirement 4) — by decision.
- **CR-distinct-from-LF** (old requirement 1) — moot under normalization.
- **The preserve-vs-normalize fork** — resolved as *normalize*.
- **The owed tokenizer measurement** and the Control Pictures fallback — moot.
- **`format-ws`'s `eof-eot` op — removed from the codebase 2026-08-14.** It
  appended a U+0004 sentinel, had no consumer, and was the one place the content
  stage deliberately emitted a C0 control into the stream — which would have
  collided with rule 3. Deleted rather than exempted (suite 52 → 51 asserts;
  14-suite battery 722/722 green).

### Open — none in the codec

One adjacent item survives elsewhere and is *not* a codec concern:
source-encoding detection at ingest (ledger #17a), which is an ingest-correctness
question rather than a payload declaration.

## Escape regime — the 2026-08-09 litigation (SUPERSEDED — evidence, not guidance)

Retained as receipts. It concluded on `\` **with** self-escaping, a **total**
codec, and a **preserve-EOL** stance — all three retired above. What survives is
the measurement record, and it is what makes the revision a narrowing rather than
a guess. Load-bearing figures:

| finding | measurement |
|---|---|
| production C# payload, 70 shards | `\n` 51617 (87.8%) · `\"` 7050 (12.0%) · `\\` **127 (0.22%)** · `\t` 6 |
| self-escape tax, PowerShell (worst realistic corpus) | 16123 newlines vs 545 backslashes → **+3.4%** |
| self-escape tax, markdown | 6809 vs 228 → +3.3% |
| sigils disqualified by frequency | backtick 64.4% in md · `@` 7.2% in PS · `~` 0% PS / 1.4% md |
| Control Pictures across 114 repo source files | **0 occurrences** |
| token cost | `\n` ~1 (merged BPE token); any exotic 2–3 byte code point ≈1 token/byte → +2/line ≈ **+100k tokens on a 2 MB shard** |

The `\"` row is the one that still matters going forward: **12% of every escape in
that payload was JSON quote residue**, which length-prefix framing makes
unnecessary — v3 drops that entire class by construction, and it is a larger
legibility win than any sigil choice.

Everything from here to §"Store vs view" is the original analysis, preserved
verbatim. Read it only for the evidence behind a specific choice; its
recommendations are not current.

### Original framing (2026-08-09)

Requirement from the user at the time: **handle the different kinds of newline,
at least LF and CRLF.**

### What ConvertTo-Json does — measured, not recalled (pwsh 7.6.3)

Reference point only; we are not bound by it. `a<CHAR>b` → `ConvertTo-Json -Compress`:

| input | emitted | | input | emitted |
|---|---|---|---|---|
| `\` backslash | `\\` | | TAB U+0009 | `\t` |
| `"` quote | `\"` | | VT U+000B | `\u000b` |
| `/` slash | `/` *(not escaped)* | | FF U+000C | `\f` |
| LF U+000A | `\n` | | BS U+0008 | `\b` |
| CR U+000D | `\r` | | SOH U+0001 | `\u0001` |
| CRLF | `\r\n` | | NEL U+0085 | `\u0085` |
| DEL U+007F | *(raw, not escaped)* | | LS / PS U+2028/9 | `\u2028` / `\u2029` |

**Its newline policy is PRESERVE, not normalize**: LF, CR and CRLF each escape to
distinct sequences, and a `ConvertTo-Json` → `ConvertFrom-Json` round-trip returns
all three byte-exact (verified — `0D 0A`, `0A`, and a lone `0D` all survive
identical). It also escapes past the RFC minimum — NEL, LS, PS — which is the right
instinct, since LS/PS are line terminators to a JavaScript reader. It leaves DEL
raw, which is an inconsistency we need not copy.

### What the length prefix buys — scope the requirement correctly

**Framing never depends on encoding** (see §Design elements, length-prefix bullet).
The content span is length-delimited, so a parser needs *no* escaping to find the
frame. That collapses the requirement to two things, and it is worth keeping them
apart because they have different owners:

- **HARD — the one-record-per-line invariant.** A record must not span lines. Only
  characters a reader might break a line on threaten this. That set, and nothing
  else, is mandatory: LF, CR, VT U+000B, FF U+000C, NEL U+0085, LS U+2028, PS U+2029.
  (FF as a page-break is common in older C sources; LS/PS are line terminators to a
  JavaScript reader.) The invariant is only as strong as the rarest terminator it
  forgets.
- **SOFT — reader hygiene and coverage parity.** The remaining C0 controls and DEL
  don't threaten the invariant; they are escaped so the payload renders predictably
  and so the inverse stays total. Desirable, not load-bearing.

**TAB stays literal (user, 2026-08-09).** It is soft by the rule above — a tab
cannot break a row — and it is a normal text character in every corpus, unlike the
rest of C0. Escaping it costs 2 bytes where the raw character costs 1, for no
invariant benefit; LTS emitted `\t` only as `ConvertTo-Json` residue (6 occurrences
across the 70-shard C# payload, i.e. incidental). **Default: escape the hard set and
the genuinely hostile C0 controls; leave TAB as itself.** The line to draw is
text-vs-not, not C0-vs-not.

**Tab-run substitution — evaluated and declined.** An earlier LTS-era token-pinching
tactic substituted runs of tabs, with a break-even beyond which it paid. It is not
worth carrying into v3: the whitespace stage already owns indentation shape —
`rs-indent`'s `detab` / `min-indent-2` / `tabify` (tabify exists precisely to
collapse leading space runs to single tabs, which is the same economy applied where
it belongs) and `format-ws`'s trims. By the time content reaches the serializer the
runs have already been normalized, so a serializer-side pass would be re-solving a
solved problem on data shaped to defeat it.

This is the **third instance of one principle, so name it: the serializer does not
perform compaction that a content processor already owns.** EOL normalization
(`format-ws lf`), indentation shape (`rs-indent`), and now whitespace-run
substitution all sit at the content stage, where they are opt-in per profile and
receipted per-entry in `Processing`. The serializer's job is the line invariant and
nothing else. A compaction with no receipt is a compaction nobody can audit.

Everything JSON escapes for *its* parser — quotes, the field delimiter, forward
slash — is **not our problem**: the length prefix already handles it, content is the
final field, and `|` is filesystem-invalid so paths never collide.

### Requirements on our regime

1. **CR must encode distinctly from LF**, so CRLF stays recoverable. Folding CR into
   LF at the codec layer would make CRLF and LF indistinguishable on decode — a
   silent, unrecoverable loss, and the thing that would break a preservation stance.
2. **The codec must be total** — able to encode any input without loss or ambiguity.
   It may not lean on the upstream NUL guard for U+0000: guards belong to profiles,
   totality belongs to the format. Note `format-ws`'s `eof-eot` op deliberately
   appends **U+0004** to content, so the pipeline provably emits C0 controls into the
   content stream; the codec has to handle them.

   *Why totality, given nobody rehydrates* (user, 2026-08-09): the round-trip posture
   is **a design constraint, not an operational feature**. No decoder is being
   written and code is never reconstructed from snapshots — the imperative is that it
   *could* be, if a span were deserialized into a compiler or interpreter. Keep the
   discipline because it forces honest decisions (it is what rules out silent
   normalization and lossy folds), but do not spend reader tokens buying fidelity
   nobody will exercise. That is the reasoning behind leaving TAB literal below, and
   behind escaping the hard set rather than everything JSON would.
3. **Coverage target: ConvertTo-Json's set, plus DEL** (user). DEL is U+007F, the
   ASCII delete control — a paper-tape relic (all seven holes punched) that sits just
   past printable ASCII rather than in the C0 block, which is why JSON's
   control-character rule misses it and `ConvertTo-Json` emits it raw. It is a
   character like any other to an encoder: tokenize it, round-trip it. Taking C0 +
   DEL whole is simpler to state and to implement than JSON's set-minus-one.
4. **Self-escape obligation is conditional on the sigil, not universal.** If the
   escape marker is a character that can occur in source, it must escape itself, or
   encoded and literal forms become indistinguishable. With `\` as the marker this is
   the landmine — source code is saturated with literal backslash-n, and LTS only
   survives it by inheriting `\\` from its `ConvertTo-Json` hop
   (`RepoSnapshotLts.psm1:2112`), which v3 does not have. Choosing a marker that
   cannot occur in source would *dissolve* the obligation rather than discharge it —
   but every such marker is exotic, and exotic costs tokens. **Resolved below in
   favor of discharging it: `\` → `\\`, at a measured 3.4%.**

### Sigil selection — invisible vs visible marker

Measured against `format-ws`'s actual ops:

| candidate | UTF-8 B | visible | `strip-zwsp` | NFC |
|---|---|---|---|---|
| ZWSP U+200B · ZWNJ U+200C · ZWJ U+200D | 3 | no | **STRIPPED** | ok |
| WJ U+2060 · BOM U+FEFF | 3 | no | **STRIPPED** | ok |
| SHY U+00AD | 2 | no | **STRIPPED** | ok |
| PUA U+E000 | 3 | no (tofu) | ok | ok |
| Control Pictures U+240A / U+2421 / U+241B | 3 | **yes** | ok | ok |

**`strip-zwsp` RESERVES the invisibles — it does not disqualify them (user,
2026-08-09).** The op runs at the content stage, upstream of serialization, so by
the time content reaches the serializer those code points are *guaranteed absent*.
That is collision-freedom handed over for free, and it is the same structural move
the format already makes with ` | ` — the delimiter is safe because `|` is
filesystem-invalid, not because anything escapes it. Reserving a character class by
construction beats escaping it. (An earlier draft read the strip as a veto, on a
re-ingest argument; what survives of that is below, and it is a footnote.)

**Don't let the codec DEPEND on the reservation — let it BENEFIT from it.**
`format-ws` is opt-in per profile and its op list is caller-subsettable, so
"invisibles cannot appear in content" is profile-dependent, not absolute. A
serializer assuming it would be trusting a content-stage op to have run — the same
cross-stage coupling this design refuses elsewhere. Cheap fix: the serializer
escapes its own marker (doubling) regardless, so correctness is self-contained and
the reservation's real value is that the escape **never fires in practice**.

**Known property, not a veto — re-ingest deletes invisible markers.** If a snapshot
is itself ingested later (this repo takes selfies), `strip-zwsp` removes the sigils
from the nested copy, so encoded breaks vanish with no residue, where `\n` or ␊
would survive as visible text. Narrow — payloads are ephemeral views, not stores,
and snapshot output is normally excluded from ingest. Worth a line in the manifest
declaration, not a design change.

**Two objections do survive, both about transport and the reader:**

- **Silent corruption in transit — the strongest one.** This format is built to be
  uploaded, and the `.txt` extension exists precisely because transports mangle
  payloads. Web-chat pipelines, copy-paste and trojan-source sanitizers all strip
  invisibles, and when they do the payload degrades *invisibly* — line breaks gone,
  nothing to see. A visible marker fails loudly: a stripped ␊ is obvious on
  inspection. For a format addressed by byte offset, losing bytes silently is the
  worst available failure mode.
- **Reader legibility, on the project's primary axis.** The premise is a payload a
  model reads directly, no parser. `\n` and ␊ both carry strong priors — any reader
  knows what it is looking at. An invisible marker means the model sees run-on
  content with *no* indication a line ended, and line structure matters for code
  comprehension. The Instructions block can declare the codec, but that spends reader
  attention on decoding instead of on content.

**Pool size forces the mechanism.** The reserved invisible set is ~6 code points —
nowhere near the 33 needed for 1:1 substitution over C0+DEL. So *choosing invisible
entails choosing a prefix mechanism* (marker + ASCII code: `<SHY>n`, `<SHY>r`,
`<SHY>u0085`), with variable-length decoding. The self-escape problem still
dissolves — the marker cannot occur in reserved content — but fixed-width table
lookup does not survive. Byte cost per escaped newline:

| scheme | bytes | notes |
|---|---|---|
| `\n` backslash prefix | 2 | cheapest; self-escape tax on backslash-heavy content |
| `␊` Control Picture | 3 | 1:1, fixed width, visible |
| `<SHY>n` prefix U+00AD | 3 | ties the picture; invisible; prefix mechanism |
| `<WJ>n` prefix U+2060 | 4 | most expensive |

**If invisible is the direction, don't use ZWSP.** U+200B is a *break opportunity* —
it exists to tell a renderer it may wrap there, which is backwards for a marker whose
job is holding a record on one line. Prefer WORD JOINER U+2060 or ZWNBSP U+FEFF,
both explicitly no-break; SHY U+00AD is cheaper but is a soft *hyphen*, and some
renderers draw one when wrapping. U+2060 is the semantically honest pick, at 4 bytes.

**Two mechanism families, and the choice matters more than the character:**

- **A — prefix sigil** (JSON's shape): marker + code, e.g. `\n`. Variable-length,
  and **always** carries the self-escape obligation, whatever marker you pick — every
  ASCII character occurs in source somewhere. Swapping `\` for `~` or `^` only
  changes how often the tax fires, not whether the mechanism is needed.
- **B — 1:1 codepoint substitution**: each escaped character maps to exactly one
  substitute character. No prefix, so no prefix collision, so requirement 4 dissolves
  rather than being discharged. Decoding is a table lookup — no lookahead, no
  variable-length parsing, no ambiguity.

**Control Pictures (U+2400–U+241F, plus U+2421) is purpose-built for B.**

*What a "picture" is*: Unicode set aside a block whose entire job is to give each
non-printable ASCII control character a **printable stand-in glyph** — a tiny
picture of that character's name drawn in one cell. ␊ is a miniature "LF"; ␉ is
"HT"; ␀ is "NUL". They exist so a terminal or editor can *show you* a control
character without emitting one. That is exactly this problem — a visible stand-in
for a character we must not emit — which is why the block is the natural fit rather
than a clever repurposing.

One per C0 code point, with clean arithmetic — C0 char `n` → `U+2400 + n` — verified:
LF→␊, CR→␍, TAB→␉, VT→␋, FF→␌, NUL→␀, ESC→␛. DEL is the one special case: **U+2421**,
because U+2420 is taken by SPACE. So the block covers C0 + DEL exactly — precisely
the coverage target in requirement 3, no set-minus-one bookkeeping.

Why it fits here specifically: it is **visible and self-documenting** (a reader sees
␊ and knows what it is, with no spec lookup — the payload stays readable-without-a-
parser, which is the format's whole premise); it survives every pipeline op and NFC;
and it **occurs zero times across 114 of this repo's own source files** (scanned:
`.ps1`, `.psm1`, `.md`, `.json`). Preservation is automatic — CRLF becomes ␍␊ and
round-trips exactly.

Two loose ends, both cheap:

- **NEL/LS/PS have no pictures** (they are not C0), and they are in the hard set.
  Needs a general fallback form — proposal: **␛ + 4 hex digits**, using the ESC
  picture as the "an escape follows" introducer. Thematically honest, and it gives
  the regime an extension path for anything added later.
- **Self-collision**, if a substitute ever appears in source: double it (`␊␊` = a
  literal ␊), the SQL-quote trick. It costs nothing in a corpus where it never fires.

**The honest counterargument is cost, and it is not settled.** A Control Picture is
3 UTF-8 bytes against 2 for `\n`, on the single most frequent escape — one per line.
Per 1000 lines: 3000 bytes vs 2000. Bytes are the easy half; **token** cost is what
matters here and cannot be settled without the target tokenizer — `\n` is
near-certainly one BPE token, while a Control Picture may be one to three. **Measure
before committing.**

### Token economy decides it — and it inverts the recommendation

**Rarity and token-cheapness are the same axis, inverted.** BPE vocabularies are
built by frequency over training corpora, so a code point rare enough to be *safe*
(nobody writes it) is rare enough to be *absent from the vocabulary* — and absent
means byte-fallback, roughly one token per UTF-8 byte. **The property that makes an
exotic character safe is the property that makes it expensive.** No single exotic
code point escapes that trade: not Control Pictures, not ligatures (ﬁ U+FB01), not
the small-punctuation blocks (․ ‥ ⁃ ‚). They are all 2–3 byte rarities, and all cost
~1 token per byte.

The comparison that matters is not *escape vs. nothing* — it is the escape against
the raw newline it replaces, which was itself ~1 token:

| scheme | bytes | est. tokens | delta vs raw LF | safe? | visible? |
|---|---|---|---|---|---|
| RS U+001E, direct 1:1 substitute | 1 | ~1 | ~0 | yes (C0, absent from text) | no |
| **`\n` backslash prefix** | **2** | **~1** | **~0** | needs `\\` — measured below | yes |
| `<US>n` C0 prefix | 2 | ~2 | +1 | yes | no |
| `␊` Control Picture | 3 | ~3 | **+2** | yes | yes |
| `<SHY>n` | 3 | ~3 | +2 | yes | no |
| ligature / exotic punctuation | 3 | ~3 | +2 | yes | marginal |
| `<WJ>n` | 4 | ~4 | +3 | yes | no |

`\n` is near-certainly a *single merged token* in any code-trained vocabulary — it
is one of the most frequent two-character sequences in existence (every C, Python,
JS, Java string literal; every JSON document). That is exactly what makes it cheap,
and it is unavailable to any character chosen for obscurity.

**Scale check.** A 2 MB shard at ~40 bytes/line is ~50k lines. Control Pictures at
+2 tokens/line is **+100k tokens on one shard** — a rounding error in bytes, a
catastrophe in the currency this project actually spends.

### Measured: what the backslash self-escape actually costs

The objection to `\` was never token cost — it was the self-escape obligation. So
measure it, on the corpus most hostile to it (PowerShell: Windows paths *and*
regex):

| corpus | newlines | `\` occurrences | self-escape tax |
|---|---|---|---|
| reposnapshot `.ps1`/`.psm1` — 40 files, 677 KB | 16123 | 545 | **+3.4%** |
| reposnapshot `.md` — 24 files, 432 KB | 6809 | 228 | **+3.3%** |

**3.4% in the worst realistic case.** The "unbounded worst case" framing in the
previous draft was true in theory and negligible in practice. For contrast, the same
scan kills two alternatives outright: backtick is **64.4%** in markdown (and is
PowerShell's own escape character), `@` is 7.2% in PS. Tilde measured 0% in PS and
1.4% in markdown — genuinely rare, but a rare ASCII prefix makes `~n` an *uncommon*
byte pair, so it likely costs 2 tokens where `\n` costs 1. **Rarity in source buys
fewer self-escapes and costs more per escape, and newline escapes outnumber
self-escapes ~30:1 — so the per-newline cost dominates every time.**

### Recommendation — revised to `\` (backslash prefix)

Superseding the Control Pictures recommendation above, which optimized reader
legibility at a token price this project should not pay. `\n` is ~1 token, visible,
universally understood by any reader without an Instructions-block lookup, and its
one real cost is measured at 3.4%. Requirement 4's self-escape obligation is
*discharged* rather than dissolved — `\` → `\\`, unconditionally — and that is fine,
because the tax is small, bounded, and now quantified rather than feared.

Control Pictures remain the right answer to a *different* question: they are the
better choice if a payload is meant for human inspection or debugging rather than
model consumption, and they stay documented above for that reason.

**One cheaper option exists, with a real caveat.** RS U+001E (Record Separator) is a
1-byte C0 control designed precisely as a data delimiter, absent from text by
construction, and it does not threaten the line invariant. It would be the cheapest
possible scheme. Against it: it is invisible (both surviving objections apply), and
raw C0 bytes in a `.txt` file trip the control-character heuristics external tools
use to classify a file as binary — the same class of hazard the `.txt` extension
exists to dodge, and one our own NUL-only binary guard would not catch. Worth
knowing about; not worth the transport risk without testing the target pipelines.

**Still owed: a real tokenizer measurement.** The token column above is estimated
from BPE structure, not measured. The *direction* is robust — byte-fallback for
out-of-vocabulary code points is structural, not incidental — but the exact
multiples are not, and this decision now rests on them.

### Two objections retired by the user (2026-08-09) — and what is left

- **Renderer behavior is not a concern.** If an IDE draws something for a substitute
  glyph while viewing a shard, that is fine. This retires the ZWSP-is-a-break-
  opportunity point and the SHY-draws-a-hyphen point entirely — they were about
  rendering, and rendering is not the consumption path.
- **Misinterpretation is handled by declaration.** The substitution table ships *in
  the artifact* — tree file, or a shard header/row-zero block. This is the right
  home and it costs almost nothing: the format **already** declares its column schema
  in the header row, CSV-style, so a codec dictionary in the same place is the
  existing doctrine applied to one more thing rather than a new mechanism. It also
  gives ledger #16 a concrete carrier instead of an unplaced obligation.

  **What that dictionary is FOR — a cipher key, not a decoder spec** (user,
  2026-08-09). The manifest is *never* a decoder. Payloads are prepared to be read
  **as-is, without tooling**; that is the format's premise. The dictionary exists so
  the reading model has *read the correspondence* between sigil and original
  character before it meets one, and can carry that mapping internally while it
  reads. It is addressed to a model's in-context bookkeeping, not to a parser.
  Two consequences: it belongs **ahead of** the content it explains (header/row-zero
  or the tree, never a trailer), and it should be written as a short legible
  correspondence a reader absorbs once — not as a formal grammar. This also sets its
  price correctly: paid once per shard, against a substitute paid once per line.

**What survives is cost, and only cost.** Declaration fixes *correctness*; it cannot
fix *price*. The dictionary is paid once per shard; the substitute is paid once per
line, and that is where the money goes. Concretely, on a 2 MB shard (~50k lines,
very roughly ~500k tokens of content):

| substitute | est. extra tokens/line | shard inflation |
|---|---|---|
| `\n` | ~0 (vs the raw newline it replaces) | ~0% |
| `␊` at 2 tokens | +1 | **~10%** |
| `␊` at 3 tokens | +2 | **~20%** |

A secondary point, weaker but real: `\n` requires the reader to do *nothing* — the
mapping is native to every model that has read code. A declared table asks the reader
to hold and apply a mapping across a long payload, which is the class of
instruction-following that decays with context length — the same lost-in-the-middle
problem this format is designed around. ␊ is not opaque (it is a visible separator,
and carries a weak prior of its own), so this is a small effect, not a
disqualification. It should not outweigh a measurement.

**So: is ␊ viable? Yes — technically it satisfies every hard requirement, and with
the header dictionary it is correct.** The recommendation stays `\` only because of
the table above. **If a measurement shows the substitute costs ≤1 extra token per
line, the ~10% is a defensible price for a fixed-width, self-escape-free,
visually-explicit codec** and the choice reasonably flips.

### Escape-layer collision — the strongest argument against `\` (user, 2026-08-09)

`\` is the escape character *in the languages this tool most wants to ingest* — C,
C#, Java, JS/TS, Python, and every regex dialect. The language-expansion priority in
`TODO.md` is precisely that list. So a backslash codec stacks its escape layer on top
of the source's, and the two are **indistinguishable by inspection**.

Take a real C# line, as it sits on disk:

```
var s = "C:\\Users\\me\n";
```

| codec | emitted row content |
|---|---|
| backslash | `var s = "C:\\\\Users\\\\me\\n";\n` |
| substitution | `var s = "C:\\Users\\me\n";␊` |

The substitution row **is the source, verbatim**, plus one mark at the line boundary.
The backslash row is not: every backslash doubled, so a reader must unescape one
layer before the C# reads as C#, and `\\n` now means *literal backslash-n* to anyone
reading it with language semantics — the exact inverse of what the source said. This
is the familiar unpleasantness of reading code embedded in JSON, and it is worst on
the densest material: string literals, regexes, Windows paths.

**The invariant that separates the two schemes:** substitution never rewrites a
character of the source — it only *adds* marks where line breaks were. Backslash
escaping *alters existing characters*, so the payload no longer shows the reader what
the file says. That is a difference in kind, not degree.

It also changes what the header dictionary is *for*. Under substitution the reader
needs no dictionary to read the code correctly — the code is unaltered; the
dictionary only serves byte-exact reconstruction, which is tooling's job. Under
backslash the reader needs the dictionary to read correctly at all, and must apply it
per-occurrence, mid-stream, indefinitely.

**And it reframes the 3.4% measurement.** That figure is a *frequency*, and it
settled the token question — correctly. It says nothing about confusion, because the
confusion is not uniformly distributed: those 545 sites sit in string literals,
regexes and paths, the most semantically loaded lines in the file. A low rate of
ambiguity in the highest-value spots is not the same as a low cost.

Middle options are dominated and can be dropped: `~n` still needs self-escaping
(1.4% in markdown), still costs ~2 tokens as an uncommon byte pair, and still
half-collides with source syntax — strictly worse than ␊ on two axes of three.

### The Compaction block — where the cipher key lives (user, 2026-08-09)

**The tree file is the exclusive entrypoint and is read first, by design.** That is
what makes it the correct carrier: a dictionary there precedes all shard content *by
construction*, satisfying the ahead-of-what-it-explains rule with no extra
discipline. The tree already carries export settings a reader may need (`Strategy |
Grouping | Packing | MaxShardSpanBytes | Created | Shards`), so a **Compaction**
field extends an existing habit rather than introducing one.

Shape: a short list of the substitutions **actually made**, verbatim. Note that
"made" is doing real work — this is a **receipt, not a capability catalog**. Only
what this artifact actually applied gets listed, which matches the format's standing
rule that header and rows always agree and the schema describes exactly what the
rows contain. A reader seeing no `\r` entry thereby learns something true: no CR
survived into this payload.

**One precision fix on the tuple.** The right-hand side must name the character,
since it cannot be shown — correct, and unavoidable. But `{newline}` is ambiguous
across LF / CR / CRLF, which is exactly the distinction the preserve stance exists to
maintain; a dictionary that blurs it undoes the codec's one hard guarantee. Name the
character *and* its code point:

```
## Compaction

Content spans are line-compacted so each row holds exactly one logical line.
Substitutions below apply to the content field only:

  \n  ->  LF  U+000A   (the original line break)
  \r  ->  CR  U+000D
  \\  ->  \   U+005C   (a literal backslash in the source)
```

**Why naming works — and it is not a byte-level mechanism.** The block functions as
*instruction the model reads*, not as data the model decodes: the correspondence
lands because it is stated in prose the reader parses, the same way the Instructions
block lands. That reinforces the cipher-key framing and has a practical consequence —
**write it to be read**. Names and code points beat clever notation; a line of gloss
is worth more than a denser table. It stays cheap regardless: paid once per artifact
against a substitute paid once per line.

**Settled: per tree, not per shard (user, 2026-08-09).** The per-shard duplication I
floated was solving a non-problem, because it mixed up the two delivery eras:

- **Tool-free path** — the payload stands alone, the tree is the exclusive entrypoint
  and is read first, so the key always precedes the content. Everything in this
  section is written for this path, and it is the only path that needs a cipher key
  at all.
- **MCP path** — a tool sits in between, so the constraints change entirely. The
  server can **nudge** (guidance elevated into the tool contract), and more to the
  point it can **return decoded content spans** — the reader never meets an escape,
  so it never needs the key. A shard fetched without the tree is not a reader holding
  an undecipherable payload; it is a reader being handed plain text.

**The codec is therefore an artifact-transport concern, not a reader concern,
whenever a tool sits in the path.** Same progressive-enhancement shape the surface
already has (§mcp-surface "two-era design"): degrade gracefully to tool-free, get
better with tools — the compaction key is exactly the kind of thing the tool era
makes unnecessary rather than the kind it has to reimplement.

*Consequence worth recording:* this gives requirement 2's totality a **real
operational consumer**. An MCP that decodes spans is a decoder — a decode-only one,
not the rehydrate-to-compiler path, which stays theoretical. So "the codec must be
unambiguous" stops being pure design discipline the moment the MCP lands.

**Implementation site is concrete and already exists**: `rs.core.template.ps1` fixes
the artifact's section sequence (Title · SummaryLine · Payload · Instructions ·
Tree), so this is a new optional `{{#if Compaction}}` section plus a model-builder
field — the same config/code separation the template was built for. Place it before
the Tree block; adjacent to Instructions is natural, since both are reader guidance.

### Ground truth — a production LTS C# payload (measured 2026-08-09)

The argument above is sound in *kind* and was badly wrong in *magnitude*. Measured
against a real LTS snapshot of a C# codebase — `project-snapshots/ThermoMapper/
src_20260701_122622`, 70 shards, non-overlapping scan:

| escape | count | share of all escapes |
|---|---|---|
| `\n` — encoded newline | 51617 | 87.8% |
| `\"` — escaped quote | 7050 | **12.0%** |
| `\\` — escaped backslash | **127** | **0.22%** |
| `\t` | 6 | 0.01% |

**The escape-layer collision is 127 sites across 70 shards — ~1.8 per shard, a 0.25%
tax against newlines.** C# simply does not carry many literal backslashes; the 3.4%
measured earlier is a PowerShell artifact (Windows paths and regex), and PowerShell
is not the ingestion target the concern was about. An order of magnitude smaller than
the framing above implied, and the user's own calibration — *"not necessarily that
confusing, but still"* — was the accurate one.

**The finding that matters is the other row: 12% of every escape in that payload is
`\"`, and it is pure JSON residue.** Quotes need no escaping under length-prefix
framing (content is the final field, the frame is declared) — so **v3 drops that
entire class by construction**, just by not having the `ConvertTo-Json` hop. This is
also where the real readability damage lives. From the payload verbatim:

```
return '\"' + text.Replace(\"\\\"\", \"\\\"\\\"\") + '\"';
```

against the source it came from:

```csharp
return '"' + text.Replace("\"", "\"\"") + '"';
```

Almost all of that soup is quote escaping, not backslash escaping. Removing it is a
larger legibility win than any sigil choice, and it is already banked.

**Verdict: `\` stands, and more firmly than before.** On the actual target language
the collision costs 0.25% and ~1.8 sites per shard, against 10–20% token inflation
for substitution. The scheme also has years of production use behind it in LTS
payloads. Control Pictures stay documented as the better answer for
human-inspection payloads and as the fallback if a tokenizer measurement ever comes
back showing the substitute is ~free — but nothing in the measured evidence asks for
the switch.

Worth noting the two schemes have different cost *shapes*, not just sizes:
backslash-prefix taxes content that contains backslashes — regex-heavy, path-heavy,
LaTeX-ish code, where the worst case is unbounded — while substitution taxes every
line by a fixed amount and is flat regardless of content. Which wins depends on the
corpus, so measure on real material, not a synthetic file.

### Open fork — does the codec preserve or normalize EOLs? — CLOSED: normalize

**Resolved 2026-08-14 against the recommendation below.** The section argues
*preserve*, on stage-ownership and losslessness grounds. Both premises were
retired: losslessness has no consumer once rehydration is off the table, and
stage ownership was mis-drawn — encoding the line breaks that survive into the
container is the container's job, distinct from `format-ws`'s job of normalizing
CRLF within content. Every terminator now folds to `\n`. The reader-noise cost
this section names as preserve's downside (`\r\n` on every line of
Windows-origin files) is the concrete win.

- **Preserve** (ConvertTo-Json's policy): CRLF → `\r\n`. Lossless; the codec stays a
  pure transport concern with zero content semantics. Cost: `\r\n` on every line of
  Windows-origin files — visible reader noise and one extra token-ish char per line.
- **Normalize**: fold CRLF/CR → LF, emit only `\n`. Cheapest and cleanest for the
  reader. Lossy, and would owe a manifest declaration so nobody reconstructs files
  with the wrong terminators.

**Recommendation: preserve — and note this is continuity, not a new proposal.**
EOL policy already has an owner at the content stage, in both generations:
`RepoSnapshotLts.psm1:777` (`Normalize-FileContent`) folds CRLF and CR to LF
*before* serialization, and `ConvertTo-Json` (`:2112`) then escapes only the LF
that survives. `format-ws`'s `lf` op is the v3 successor of that line — default-on,
documented as *run first* because application order is a correctness invariant, and
receipted per-entry in `Processing`. So the split we would be adopting is the one
already in force; what changes is only that the serializer's half stops being
inherited from JSON and gets written down.

Duplicating normalization in the serializer would give the codec a second job, make
it lossy by default, and put a content decision inside a transport layer — against
the stage-ownership discipline the rest of the pipeline keeps, and against the
`Processing` receipt (a fold nobody records is a fold nobody can audit). Preserving
keeps the codec total and honest: it round-trips whatever it is handed, profiles
that want clean `\n`-only payloads get them upstream with a receipt, and the
manifest declaration (#16) can state a flat guarantee instead of enumerating
caveats.

## Store vs view (user, 2026-07-22)

- **v3 will support writing BOTH JSONL and the custom format.**
- **JSONL = the store**: data at rest, tooling-friendly — `.jidx` binary seek side-car
  (jso-jackson `[JsonlIndex]::Build`), search, deduplication mechanisms. Preferred for
  markdown/thread corpus ingestion (many documents → one indexed store).
- **Custom format = a view on the data**, optimized for LLM readers — the consumption
  artifact rendered from the store.
- **The tree manifest and its operational/metacognitive guidance** (Instructions block;
  instruction sets in `rs.core.template.ps1`) **are first-class features of the
  payload**, not garnish — the guidance ships with the data.

## Configurability doctrine

- **Every payload is read on its own self-documented merits.** Readers parse exactly
  what the header declares — never a fixed column set, never tool-version assumptions.
  Policy lives in *generation knobs*, not reader conventions.
- Generation knobs (LTS / v3 Partition-Files): `MaxShardSpanBytes` (+ `MaxShardSizeKB`,
  `MaxFilesPerShard`), `GroupingStrategy` (Flat / ByFileType / ByRootDirectory — group
  suffix appears in shard filenames), `PackingStrategy` (Greedy / Balanced / Loose),
  metadata toggles (`ExcludeShardMetadata`, `ExcludeAttributes`), `StripComments`,
  `IncludeFileContent`, ignore/selection patterns.
- **Shard span is reader-transport tuning**, not just context budgeting: for a
  web-surfing reader navigating the public snapshot repo, one shard = one fetch = one
  ingestion chunk (manifest as crawl plan), so `MaxShardSpanBytes` tunes to the
  reader's fetch/preview horizon. One knob serves three transports: upload size,
  fetch-page size, context-span discipline.
- **`AllowOversizedShards` — no-fragmentation stance**: when a single file exceeds the
  shard span limit, it gets a *dedicated oversized shard* rather than being split
  across shards — user's preferred default: never fragment an ingested file's
  contents. A user-settable switch, not a hard rule. Principled intra-file splitting
  becomes available only when subaddressing can cut at semantic boundaries (deferred
  track) — until then, arbitrary byte cuts are the only alternative, hence the
  oversize preference.

## Notes

- Format name: not finalized.
- The RTE-sniffing rationale applies to any artifact intended for upload — extension
  naming of rendered views is part of the view, not the store.
