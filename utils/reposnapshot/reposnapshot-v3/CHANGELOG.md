# Changelog — rs.core - formerly threadparser/v2-new

## 2026-08-15 — `schema/descriptor.json`: the field register, read by code; ignore reads `Extension`

The per-file record (descriptor → item → bag → entry — one record, four
names) had no declaration anywhere; the only field list in the codebase was
assemble's hardcoded exclusion, so adding a crawler field meant editing the
end of the line. `schema/descriptor.json` is now the one place a field is
declared — origin stage, scope (`core` / `ingestion` / `element`), type,
note — and it has teeth because code reads it (ledger #6): `rs.core.assemble`
derives `$alwaysExcluded` (scope=ingestion) and `$coreFields` (scope=core)
from it at import, failing the import loudly if the file is missing;
`crawler.tests` asserts the crawler stamps exactly the origin=crawler set
(both directions); `assemble.tests` asserts the module's exclusion set equals
the schema's. Unlisted fields are elements by default — the register declares
dispositions, it does not close the bag. `schema/assemble.schema.json` stays
as IR macro-shape documentation, marked not-read-by-code, deferring field
dispositions to `descriptor.json` instead of repeating them.

`rs.core.ignore`: reads `$f.Extension` instead of re-deriving with
`[Path]::GetExtension`, and `Extension` joins `RelativePath` in the fail-fast
descriptor-contract check (probe: a graph with `Extension` stripped throws
`lacks Extension`).

Battery: 14 suites · 806 passed · 0 failed.

## 2026-08-15 — Crawler stamps what is free at its vantage; docstring slimmed

`rs.core.crawler`: file descriptors gain `Extension`, `CreationUtc`,
`FsAttributes` (all from the stat/attribute reads the walk already makes);
graph nodes gain `SubtreeDirCount` / `SubtreeFileCount` / `SubtreeBytes`,
computed deepest-first over the in-memory graph after the walk (on-disk,
pre-filter totals; ignore rebuilds nodes so they are crawler-output facts,
not carried). Node construction factored into `NewNode`. The rule these
follow — *stamp anything free at the vantage, nothing that costs a read* — is
stated once in the docstring; rationale, path doctrine, and the old `.TODO`
block moved to `issues/reposnapshot/design/module-notes.md §rs.core.crawler`.
`FsAttributes`, not `Attributes`, to avoid the rs-attributes element.

`rs.core.assemble`: `$alwaysExcluded` extends to the three new descriptor
fields (ingestion-side facts, same class as `AbsolutePath`/`SizeBytes`), so
they neither ride into entry bags nor register in `Header.Elements`.
Verified end-to-end over `processors/`: descriptors and post-file-read results
carry them; entries and Elements unchanged.

`AGENTS.md`: new §"How to read the design docs" — target-vs-built, tests are
the only enforcement, free-at-vantage before who-consumes. Stale `issues/v3/`
pointers in AGENTS.md and the two touched modules corrected to
`issues/reposnapshot/…` (18 other files still carry the old path).

Supersedes `briefs/stage-appended-attributes-brief.md` (the mechanism is the
open-bag descriptor plus the stamping rule; nothing separate to build).

Battery: 14 suites · 790 passed · 0 failed (`crawler.tests` 26 → 46).

## 2026-08-09 — Codec settled: `\` stands on measurement; cipher key gets a home

Closes the sigil thread the four entries below leave open, and sites the key.
*(Record written 2026-08-10 during the old-tree → canonical transfer — this span
of the work shipped without changelog entries; the doc changes themselves are
contemporaneous.)*

**Escape-layer collision, then measurement — `\` stands.** The strongest
objection raised was that `\` is the escape character in exactly the languages
queued for ingestion (C#, JS/TS, Java, Python, regex), so a backslash codec
stacks its layer on the source's and `\\n` reads as *literal backslash-n* under
language semantics — the payload stops showing the reader what the file says.
Sound in kind, and settled by scanning a production LTS C# snapshot
(`project-snapshots/ThermoMapper/src_20260701_122622`, 70 shards): `\n` 51617
(87.8%), `\"` 7050 (12.0%), **`\\` 127 (0.22%)** — ~1.8 collision sites per
shard, a 0.25% tax. The earlier +3.4% figure was a PowerShell artifact (Windows
paths, regex), not a property of the C-family targets the concern was about.
The tokenizer measurement "still owed" below therefore drops from blocking to
optional; Control Pictures stay on file as the fallback.

The consequential row is the other one: **12% of every escape in that payload is
`\"`, pure JSON residue that length-prefix framing makes unnecessary** — v3 drops
it by construction, which beats any sigil choice on legibility. Filed against LTS
in `lts-v3-transfer-audit.md` so a writer does not reintroduce it by reaching for
`ConvertTo-Json` out of habit.

**The dictionary ships in the artifact, and its home is the tree.** Carrier
settled first (same place the column schema is already declared — existing
doctrine reused, not new machinery), then sited concretely: an optional
`Compaction` block in the **tree file**, placed before the Tree block. The tree
is the payload's exclusive entrypoint and is read first, so the key precedes all
shard content *structurally* rather than by a rule someone has to remember. It is
a **receipt of substitutions actually made**, not a capability catalog — an absent
`\r` entry tells a reader no CR survived. Each entry names the target character
*and* its code point (`\n -> LF U+000A`), since a bare `{newline}` would blur the
LF/CR/CRLF distinction the preserve stance exists to keep. Implementation site
queued in the `rs.core.template.ps1` docstring (`{{#if Compaction}}` section plus
a model-builder field). Ledger #16 carries the full statement.

**Per tree, not per shard — because the MCP path does not need the key at all.**
Fetch returns content with the codec already **undone**, so a reader behind a tool
never meets an encoded character. The cipher key exists for the tool-free path,
which is the same progressive-enhancement shape the surface is already designed
around: the tool era makes the key *unnecessary* rather than reimplementing it.
Two riders recorded on `issues/mcp-surface.md` — the MCP becomes **the only real
decoder in the system**, which turns the codec's totality requirement from design
discipline into an operational dependency the day it ships; and **decoded spans
break byte-offset arithmetic**, since tree offsets address the *encoded* artifact,
so the fetch contract must either return offsets alongside or make the decode
explicit in the response shape.

## 2026-08-09 — Codec: dictionary is a cipher key; TAB literal; LTS quote-escape defect

Four clarifications from the user, each changing a rationale rather than a rule.

**The manifest is never a decoder.** Payloads are prepared to be read **as-is,
without tooling** — that is the format's premise. So the substitution dictionary is a
**cipher key addressed to the reading model**, not a decoder spec: it exists so the
model has absorbed the sigil↔character correspondence before it meets one and can
carry the mapping internally while reading. Consequences recorded: it must sit
*ahead* of the content it explains (header/row-zero or tree, never a trailer), and it
should read as a short legible correspondence rather than a formal grammar. Ledger
#16 updated — it had the carrier but the wrong purpose attached.

**Round-trip is a design constraint, not an operational feature.** No decoder is
being written and code is never rehydrated from snapshots; the imperative is that it
*could* be, if a span were fed to a compiler. Keep the discipline — it is what rules
out silent normalization and lossy folds — but do not spend reader tokens buying
fidelity nobody exercises. This is now the stated reasoning behind escaping the hard
set rather than everything JSON would.

**TAB stays literal.** It is soft by the line-invariant rule (a tab cannot break a
row) and is ordinary text in every corpus, unlike the rest of C0. Escaping costs 2
bytes where the character costs 1, for no invariant benefit; LTS's `\t` was
`ConvertTo-Json` residue (6 occurrences in 70 shards). The line to draw is
**text-vs-not, not C0-vs-not**.

**Tab-run substitution evaluated and declined.** The LTS-era token-pinching tactic
does not carry forward: `rs-indent` (`detab` / `min-indent-2` / `tabify` — tabify
exists precisely to collapse leading space runs) and `format-ws` already own
indentation shape, so by serialization the runs are normalized and a serializer pass
would re-solve a solved problem on data shaped to defeat it. **Third instance of one
principle, now named: the serializer does not perform compaction a content processor
already owns.** EOL normalization, indentation shape, whitespace runs — all content
stage, all opt-in per profile, all receipted in `Processing`. A compaction with no
receipt is one nobody can audit.

**LTS quote-escaping filed as a defect** (`lts-v3-transfer-audit.md`): 7050 `\"`
escapes, 12.0% of all escapes in the measured payload, pure JSON residue that
length-prefix framing makes unnecessary. v3 drops it by construction; the note exists
so a writer does not reintroduce it by reaching for `ConvertTo-Json` out of habit.

## 2026-08-09 — Sigil resolved to `\` on token economy (supersedes Control Pictures)

User raised token cost against the 3-4 byte markers. Measured, and it **inverts the
recommendation** — the interim Control Pictures pick optimized reader legibility at
a price this project should not pay.

**The governing insight: rarity and token-cheapness are the same axis, inverted.**
BPE vocabularies are frequency-built, so a code point rare enough to be *safe*
(nobody writes it) is rare enough to be *out of vocabulary* — and that means
byte-fallback at ~1 token per UTF-8 byte. This is structural, not incidental, and it
condemns the whole exotic-character direction the question was pointed at: Control
Pictures, ligatures (ﬁ), the small-punctuation blocks (․ ‥ ⁃), zero-widths. All land
at 3-4 bytes ≈ 3-4 tokens against a raw newline's ~1. On a 2 MB / ~50k-line shard,
Control Pictures cost **+100k tokens** — a rounding error in bytes, a catastrophe in
the currency actually being spent.

`\n` is near-certainly a *single merged token* in any code-trained vocabulary. Being
the most common escape sequence in existence is exactly what buys that, and it is
unavailable to anything chosen for obscurity.

**The objection to `\` was never token cost — it was self-escaping. So it was
measured**, on the corpus most hostile to it (PowerShell: Windows paths *and* regex):

| corpus | newlines | `\` | tax |
|---|---|---|---|
| `.ps1`/`.psm1`, 40 files, 677 KB | 16123 | 545 | **+3.4%** |
| `.md`, 24 files, 432 KB | 6809 | 228 | **+3.3%** |

The earlier "unbounded worst case" framing was true in theory and negligible in
fact. The same scan disqualified alternatives outright: backtick **64.4%** in
markdown (and PowerShell's own escape character), `@` 7.2% in PS. Tilde is genuinely
rare (0% PS / 1.4% md), but a rare ASCII prefix makes `~n` an uncommon byte pair —
likely 2 tokens where `\n` is 1. Newline escapes outnumber self-escapes ~30:1, so
per-newline cost dominates every time.

Kept on file rather than discarded: **Control Pictures** for payloads meant for human
inspection or debugging rather than model consumption; **RS U+001E** as the one
genuinely cheaper scheme (1 byte, a C0 delimiter by design) — rejected on transport
risk, since raw C0 bytes trip the binary-classification heuristics external tools
apply to `.txt`, a hazard our NUL-only guard would not catch.

**Still owed: a real tokenizer measurement.** The token figures are estimated from
BPE structure. The direction is robust; the exact multiples are not, and the decision
now rests on them. *(Superseded by the entry above — the production-payload scan
settled it and demoted this to optional.)*

## 2026-08-09 — Sigil: strip-zwsp RESERVES the invisibles (correction)

**User correction to the entry below, and it inverts that argument.** `strip-zwsp`
deleting the zero-width characters does not disqualify them as escape markers — it
**reserves** them. The op runs at the content stage, upstream of serialization, so
those code points are guaranteed absent from anything the serializer sees.
Collision-freedom for free, and the same structural move the format already makes
with ` | `, which is safe because `|` is filesystem-invalid rather than because
anything escapes it.

The "destroys its own output on re-ingest" framing was overweighted and is demoted
to a noted property: re-ingest does delete invisible markers where `\n` or ␊ would
survive as text, but payloads are ephemeral views and snapshot output is normally
excluded from ingest.

Rider added: the codec should **not depend** on the reservation — `format-ws` is
opt-in and its op list is caller-subsettable, so the guarantee is profile-dependent.
The serializer self-escapes by doubling regardless; the reservation's real value is
that the escape never fires.

Section rewritten as **two coherent designs** rather than a verdict:

- **Reserved-invisible prefix** — U+2060 WJ, 4 bytes/newline, pristine-looking
  payload. Pool size forces a prefix mechanism: ~6 reserved code points against the
  33 needed for 1:1 over C0+DEL. Noted: **not ZWSP** — U+200B is a break
  *opportunity*, semantically backwards for a marker whose job is holding a record
  on one line.
- **Visible 1:1 substitution** — Control Pictures, 3 bytes/newline, fixed-width
  table lookup.

Recommendation still favors visible, but now rests only on the two objections that
survive the correction: **silent** corruption in transit (stripped invisibles leave
no trace — the worst failure mode for a byte-addressed format, where a mangled ␊ at
least fails loudly), and reader legibility on the project's primary axis (an
invisible marker hides line structure from the model the payload exists to serve).
Counter-case recorded as genuine: for MCP/local delivery the transport objection
weakens, and a per-artifact split is defensible since #16 declares the codec anyway.

## 2026-08-09 — Escape regime: scope corrected by the length prefix; sigil analysis

Follow-up to the entry below, correcting its framing. **The length prefix means
escaping is never needed for parsing** — framing does not depend on encoding — so
the requirement is narrower than that entry implied. Rescoped in
`shard-format-notes.md` §"Escape regime — codec spec":

- **HARD**: the one-record-per-line invariant only. LF, CR, VT, FF, NEL, LS, PS.
- **SOFT**: remaining C0 + DEL — reader hygiene and a total inverse, not
  load-bearing.
- Everything JSON escapes for its own parser (quotes, delimiters, `/`) is simply
  not our problem.

The prior entry called backslash-escaping "non-negotiable". **It is conditional on
the sigil, not universal** — it binds only if the escape marker can occur in
source. Choosing a marker that cannot dissolves the obligation instead of
discharging it.

**Sigil question answered (user asked about invisible codepoints): no, and the
evidence is in-house.** Every zero-width candidate — ZWSP, ZWNJ, ZWJ, WJ, BOM, SHY
— is deleted by `format-ws`'s own default-on `strip-zwsp` op, whose character class
is exactly the invisible-sigil shortlist. Since snapshots get re-ingested, an
invisible sigil is a codec that destroys its own output on the second pass. They
are also undebuggable and the most transport-fragile option, against a format whose
`.txt` extension exists to survive web-chat mangling. PUA survives but renders as
tofu.

**Recommended: 1:1 codepoint substitution over Control Pictures** — U+2400+n for
C0 (verified arithmetic: LF→␊, CR→␍, TAB→␉, VT→␋, FF→␌, ESC→␛), U+2421 for DEL
(U+2420 is SPACE). Covers C0+DEL exactly, matching the coverage target. Visible and
self-documenting, NFC-stable, survives every pipeline op, and **zero occurrences
across 114 of this repo's own source files**. No prefix means no prefix collision.
Specified loose ends: ␛+4hex fallback for NEL/LS/PS (no pictures — not C0), and
doubling for self-collision.

**Not committed — a token measurement is owed first.** 3 UTF-8 bytes vs 2 for `\n`
on the most frequent escape (one per line). The schemes differ in cost *shape*, not
just size: backslash taxes backslash-heavy content with an unbounded worst case;
substitution taxes every line flatly. Measure on real corpus material.

## 2026-08-09 — Escape regime spec: newline handling, and the backslash landmine

Spec only, ahead of the serializer that will implement it —
`shard-format-notes.md` §"Escape regime — codec spec". Requirement from the user:
the serialization escaping must handle the different kinds of newline, LF and
CRLF at minimum.

`ConvertTo-Json`'s policy was **measured rather than recalled** (pwsh 7.6.3) and
recorded in the doc as a reference point: it **preserves** EOLs rather than
normalizing (LF/CR/CRLF escape distinctly and round-trip byte-exact), escapes past
the RFC minimum to cover NEL/LS/PS, and leaves DEL raw.

Requirements set for our own regime:

- **Escape the backslash.** The correctness landmine, and the reason #16 is
  load-bearing rather than tidy: LTS gets `\\` free from its `ConvertTo-Json` hop
  (`RepoSnapshotLts.psm1:2112`), and hand-authoring the codec forfeits it. Source
  code is full of literal backslash-n, which without it is indistinguishable from
  an encoded newline — an ambiguity no length prefix can resolve. Textbook case of
  the AGENTS.md caveat about barebones forfeiting inherited guarantees.
- Escape the full C0 range plus NEL/LS/PS, not just LF/CRLF — the
  one-record-per-line invariant is only as strong as the rarest terminator it
  forgets.
- Keep CR distinct from LF, so CRLF stays recoverable.
- Stay total; don't lean on the upstream NUL guard. Note `format-ws`'s `eof-eot`
  op deliberately appends U+0004 *to content*, so C0 controls provably reach the
  serializer.

One fork left to the user: preserve EOLs vs normalize. The doc recommends
**preserve**, and the LTS read makes that continuity rather than a new position —
`Normalize-FileContent` (`:777`) already folds CRLF/CR→LF at the *content* stage
and lets the serializer escape only what survives. `format-ws`'s `lf` op is that
line's v3 successor (default-on, run-first, receipted in `Processing`). Only the
serializer's half changes: it stops being inherited from JSON and gets written down.

Also fixed: the probe table in that section was first written with **literal**
control characters (0x0B, 0x01, U+0085, U+2028, U+2029) instead of the escape text
naming them — a doc about escaping line terminators containing raw ones. Rewritten
programmatically; verified zero control characters on those lines.

## 2026-08-09 — Encoding and codec sited at the serializer; upstream look-back

Doctrine pass, **no behavior changed** — docstrings, design docs and planning
only. Battery green (14 suites · 723 asserts) as a no-op check on the two
ISS-loaded processor bodies whose comment blocks were edited.

Character encoding and the content codec are **serializer-stage declarations**,
owed to the reader in the manifest (`payload-manifest-ledger.md` #16/#17). The
custom container authors its own escape regime — no `ConvertTo-Json` in that
path, and the JSONL writer's escaping stays on its own side of the wire — so
unlike a JSON payload there is no external spec a reader can fall back on when
decoding a `row_content_begin..row_content_end` span. That makes declaring the
codec the only thing that keeps a span round-trippable to source.

Siting the decision there exposed three upstream pre-commitments, all **filed,
none fixed** (consolidation §B.6e — they want deciding together, and each has a
test behind it):

- `rs.core.assemble.psm1` — `Encoding` is not in `$alwaysExcluded`, so a
  run-level constant rides into every entry bag and counts as a fully-present
  element in `Header.Elements`. Header is its home while it stays constant.
- `processors/file-read.ps1` — the `Encoding` stamp is a decode policy, not a
  detection: UTF-8 unconditionally, no BOM sniff. Also noted that UTF-16
  sources are caught by the NUL binary guard, but incidentally and under a
  misleading `BinaryOrNulContent` reason.
- `processors/rs-attributes.ps1` — byte figures are **canonical UTF-8 by
  convention**, now stated outright. Deliberate: attributes must be invariant
  to writer knobs to stay comparable across runs. Layer 2 is consequently never
  a proxy for layer 3, which the codec inflates.

**Correction, same day — no packing adjudication after all.** This entry
originally raised "which byte layer does shard packing target?" as an open
question for the user. Withdrawn: it conflated planning with measurement
(user). Shard packing *plans* against layer 2 and that is correct —
`MaxShardSpanBytes` is a policy budget and escape inflation is negligible at
shard granularity. Tree-manifest offsets are *measured off the written file*
after the fact, so nothing upstream forecasts encoded bytes and codec inflation
has nothing to corrupt. Recorded in assemble-design §"Planning vs measurement"
and as a conflation hotspot in AGENTS.md, since the wrong reading invites a
pointless "fix" to the packer.

## 2026-07-28 — Phase 1 consolidation: ItemDescriptor identity seam + colonel AST validation

Plan: `issues/v3/v3-consolidation-plan.md` · contracts: `issues/v3/rs.core.assemble-design.md`.

### rs.core.crawler.psm1 — identity stamped at walk time

- **File entries carry the full ItemDescriptor identity contract**:
  `@{ AbsolutePath; RelativePath; NodePath; SizeBytes; LastWriteUtc }`.
  `RelativePath = NodePath + name` (root-anchored, forward slashes, zero extra
  derivation); one `FileInfo` stat supplies size + last-write. Skip reason
  `FileSizeReadFailed` → `FileStatReadFailed` (no consumers). Path doctrine
  (absolute = ingestion reads only; relative = artifact-facing structural
  identity) documented in the module docstring. New `tests/crawler.tests.ps1`
  (27 asserts).

### rs.core.ignore.psm1 — pure filter + Prune infinite-loop fix

- **De-stamped**: `Invoke-IgnoreFilter` no longer computes RelativePath
  (crawler owns identity); fails fast on pre-contract graphs. **Breaking**:
  vestigial `-RootPath` parameter removed (no external callers existed).
- **`GetParentPath` return type `[string]` → `[object]`** — the `[string]`
  return coerced `return $null` to `''`, collapsing the null-vs-empty
  distinction ('' = parent is root; $null = root has no parent) and making
  Prune's ancestor walk an **infinite loop**. Surfaced on the pipeline's
  first-ever end-to-end run; C# lineage (repo-audit) returns `string?` for
  exactly this reason. Also normalized an accidental operator line-split in
  the empty-leaf prune predicate.

### rs.core.ingest.psm1 — descriptor dispatch (the seam fix)

- **Colonel Items are ItemDescriptor objects, not AbsolutePath strings.** The
  string flattening broke every chain end-to-end (`$Item.AbsolutePath` on a
  string is `$null` → every item `_ChainHalt`ed with ReadError); colonel tests
  missed it by calling `Invoke-Plan` directly with objects. Contract
  docstrings updated.

### processors/file-read.ps1 — generic copy-on-enrich

- **Clones ALL input properties** (was: four hardcoded fields, silently
  dropping `LastWriteUtc` and any future descriptor field). Copy-on-enrich
  without mutating the caller's reference remains the processor contract.

### rs.core.colonel.v2.psm1 — AST processor validation

- **Body-only contract validated via AST, not regex**: requires a top-level
  `param` block (chain-executor's positional-call contract); rejects
  non-parsing scripts with the parser message. **`#Requires` rejection now
  also AST-authoritative** (`$ast.ScriptRequirements`) — the prior pre-parse
  regex (`^\s*#\s*Requires\b`) over-matched ordinary English comments like
  `# Requires manual setup` (PowerShell's directive syntax is exactly
  `#Requires`, no space); the parser's own notion can't. Distinct from the
  comment-ontology `frontmatter` concern: colonel rejects the directive in
  processor bodies because it is inert in ISS-registered functions
  (environment is Build-Iss's); rs-psstrip protects it in ingested scripts
  because there it is live semantics sharing comment syntax. **Interior helper functions are now legitimate** — the old regex
  rejected any `function` keyword, blocking `tp-perplexity`
  (`_MaskByRegex`); it now compiles into plans and helpers execute correctly
  in dispatched runspaces. New `tests/colonel-validation.tests.ps1`
  (12 asserts). Unblocks the thread-corpus track (its open decision 6).

### processors/rs-attributes.ps1 — new processor (entry metrics)

- **Enrich-only tail step**: attaches `Attributes` (SpanBytes, CharCount,
  WordCount, PunctuationCount, UniqueChars, Entropy, CompressionRatio,
  WhitespaceRatio, LineStats{Mean, Median, StdDev, Max}) computed over
  `$Item.Content` —
  language-agnostic **by position** (after ALL content mutators; profile
  invariant, processor is position-ignorant). No-Content items pass through
  unenriched (safe in arbitrary profiles incl. thread envelopes). Provenance
  split: `SizeBytes` = on-disk stat; `Attributes.*` = processed-content
  stats. **Byte semantics (user)**: attributes deal in `SpanBytes` — the
  UTF-8 byte span of the processed content (payload-navigation semantics,
  same family as tree byte spans) — never on-disk size; LTS's
  `attributes.size_bytes` conflated the two. Formulas are LTS-parity
  (guards, 4-decimal rounding, upper-median quirk) with one deliberate
  exception:
- **LTS `compression_ratio` defect found**: LTS reads `MemoryStream.Length`
  after `GZipStream.Close()` has disposed the stream → `$null` → coerced 0 —
  every >100-char LTS entry emits `compression_ratio = 0` (verified against
  the 20260723 selfie monolith). rs-attributes reads `$ms.ToArray().Length`
  (valid after close) and emits the real ratio. Golden comparison treats
  compression_ratio as a known delta.
- `processors/tests/rs-attributes.tests.ps1` (34 asserts) — parity formulas,
  no-Content/empty-content contracts, copy-on-enrich, colonel dispatch
  (GZipStream confirmed resolving in worker runspaces).

### stage modules — docstring audit (accuracy/tightness/completeness)

- **rs.core.colonel.v2**: gained its missing module-level docstring (the
  two-call surface, AST validation summary, descriptor Items, _ChainHalt
  ownership, RunspaceManager's role as convenience holder, and why
  module-level #Requires is fine when processor-level is forbidden).
- **rs.core.ingest**: synopsis now carries the ingest reframe — proto-admiral
  tissue, not a stage; file reading is colonel's first processor;
  disposition (absorb vs submodule) open.
- **rs.core.ignore**: last stale ExecutiveOverride sentence in
  Invoke-IgnoreFilter's description replaced with the TestPath/CompiledState
  wording.
- **rs.core.sharding**: header now states the 2026-07-22 re-disposition
  (JSONL/Piped = thread-corpus store substrate, not vestigial) and the
  queued writer-phase reconciliations (ByteSpan → SpanBytes naming;
  IR-entries entry point for ConvertTo-ShardFiles).
- **rs.core.template**: "integration target" note corrected — integration
  COMPLETE (LTS consumes via Import-TocTemplateEngine); named as the
  config/code-separation precedent; the two instruction-set functions'
  copy-pasted synopses differentiated (monolith vs sharded/virtual-DB
  guidance block).
- **rs.core.internals**: documentation requirement for the reflection
  mechanism cross-referenced (admiral brief) with the accepted implications
  and current use site (ingest) named.
- **rs.core.crawler**: phantom `_build.json` reference in the factory
  example replaced with "diagnostics feed".
- Docstring-only; six stage suites re-run green (163 asserts).

### processors/* — docstring audit & modernization (fleet-wide)

- **v1 colonel API remnants purged**: "Host guidance for Colonel fluent
  setup: SetIssPreset(...)" (v1 fluent API — v2 is `Compile-Plan
  -IssPreset`) and "Supported RunMode usage: ApplyAll, KeyMatch" (RunMode
  died with v1; v2 dispatch is plan-driven) removed from format-ws,
  rs-indent, rs-csstrip, rs-psstrip, tp-perplexity — and rs-attributes,
  which had inherited the RunMode line from the stale template on creation.
- **Standardized self-documentation block**: `Item contract` / `Position
  class` / `IssPreset floor` / `Required IssModules`. Item contracts now
  DECLARED per processor (the 6d fault line made visible): descriptor
  (file-read, rs-attributes) · tp-era Text envelope with 6d pointer
  (format-ws, rs-indent, rs-csstrip, rs-psstrip — noting intra-era chains
  work; the break is cross-era only) · dual-key input → envelope output
  (tp-perplexity, verified in code: Text preferred, Content fallback).
  Position classes (reader / content mutator / enrich-only tail /
  segmenting parser) seed the operation-order doctrine's future
  precedence-class mechanical ordering.
- **"No outer function wrapper" wording updated** to the post-AST-fix
  contract (top-level param block; interior helpers legitimate — rs-psstrip
  and tp-perplexity name theirs). chain-executor's stale
  `RunspaceScripts/` path header fixed (`processors/`). rs-indent's "when
  colonel chaining is available" contingency resolved (it is; the tp-era
  stack works today, gated only by 6d for descriptor chains); stale
  `format(lf)` key reference → format-ws. rs-csstrip gains its CRLF
  side-effect note and the pending combined-alternation evaluation pointer
  (transfer-audit inventory). format-ws documented as the named precedent
  of the operation-order doctrine.
- Docstring-only changes; verified by the touched-suite battery
  (314 asserts green incl. rs-indent 39/39 and recompilation of every
  processor through colonel validation).

### rs.core.assemble.psm1 — new stage: the IR (Phase 5)

- **`Invoke-Assemble`**: collates the colonel dispatch envelope into the
  in-memory IR — `{ Header; Entries; Skipped; Diagnostics }` — the LTS JSON
  monolith's successor as data structure, never as artifact. Fixed phase
  sequence `adapt → route → derive → stamp`; policy = two parameter slots
  (`Adapter` 'Code'; `EntryRouting` 'LeanPayload' | 'KeepContentless').
- **Open element model live**: entries are self-describing property bags
  (guaranteed core RelativePath/NodePath/LastWriteUtc/Content + whatever the
  chain attached); `Header.Elements` declares observed per-element presence
  counts; assemble has zero per-element branches (proven: a fabricated
  WordCloud element is declared without assemble knowing it exists).
  Excluded from bags: AbsolutePath/SizeBytes (descriptor bookkeeping),
  `_ChainHalt` (mechanics); ReadError routed under LeanPayload, retained
  under KeepContentless. IR order = canonical ingested order.
- **Lean-payload routing**: read failures (typed by ReadError kind), null
  results, and empty content route to `Diagnostics.Routed` — `EmptyFile` vs
  `EmptiedByProcessing` distinguished via SizeBytes.
- **GOLDEN VALIDATION GREEN** (`tests/assemble.tests.ps1`, 53 asserts): full
  v3 pipeline (crawl → ignore → ingest[file-read, rs-attributes] → assemble)
  vs a live LTS `Get-RepoSnapshot` monolith over a normal-form fixture —
  content byte-exact per path key, every attribute formula-equal
  (char/word/entropy/whitespace/line-stats), `size_bytes == SpanBytes`,
  `last_write` tick-equal, and the known deltas asserted as documented
  (compression_ratio: LTS defect 0 vs v3 real; binary entries: LTS keeps
  content-less, v3 routes). **LTS is no longer load-bearing for the
  code-track data model.**
- **Finding (filed, not fixed — consolidation item 6d)**: `format-ws.ps1`
  and `rs-psstrip.ps1` speak the tp-era item contract (unpack `$Item.Text`,
  REPLACE the bag with an Id/Path/Text envelope) — incompatible with the
  descriptor contract (`Content`, copy-on-enrich): in a code-track chain
  they would destroy identity fields. Golden fixture sidesteps by using
  normal-form content (LTS `Normalize-FileContent` stages 1–3 = identity);
  content-transform parity across normalization awaits the contract
  harmonization.

### rs.core.ignore.psm1 — IngestMode: selection/ignore semantics inversion (Design v3)

- **`-IngestMode 'Ignore'|'Selection'`** on `New-IgnoreCompiler` — explicit
  run intent, never inferred from data shape. Both modes run the same
  five-stage machinery; mode branches exist only at the rim (source assembly
  + prune policy) and in `TestPath` (dual truth table). Cross-mode pattern
  params are **inert, never errors** — ergonomic defaults survive mode
  switching.
- **Ignore mode**: `IgnorePatterns` + new `IgnoreOverridePatterns` are both
  virtual root-level ignore sources merged with the sentinels — containers
  for positives and negations *by convention* (override entries are
  '!'-prefixed on merge; '!'-prefixed override entries double-negate to
  positive ignores). Overrides follow **canonical gitignore precedence**: a
  file-only negation cannot re-include content under an excluded directory —
  negate the directory (`dist/`) to rescue a branch. No separate rescue
  layer, no broadcast regex, no prune special-casing.
- **Selection mode**: new `SelectionPatterns` compiles as the selection
  regime (negations = un-keep exceptions); sentinels are not consulted (no
  scan, no I/O); directory pruning skipped (the one guarded asymmetry);
  empty/self-annihilated selection sets throw (fail-fast).
- **State shape**: two slots (`CompiledIgnore`/`ExecutiveOverride`) collapse
  to one regime-stamped `CompiledState = @{ Regime; Positives; Exceptions }`;
  `TestPath` is the single semantic authority (exceptions mean *undo the
  primary verdict* in both regimes); `Invoke-IgnoreFilter`'s inline
  semantics duplication collapses to a TestPath call.
- **Breaking**: `ExecutiveOverrides` removed (clean break — bypass behavior
  maps to Selection mode; targeted rescues map to overrides under gitignore
  rules); compiled-node/joined-node output shape changed (`CompiledState`).
- **Latent bug fixed**: empty-leaf prune leaked `Dictionary.Remove`'s bool
  return into the pipeline, corrupting `Invoke-IgnoreFilter`'s return value
  into an array — masked until Selection mode made empty leaves common.
- New `tests/ignore.tests.ps1` (27 asserts): virtual-file semantics,
  override rescue/double-negation/gitignore-constraint + directory-negation
  recipe, cross-mode inertness, pure selection, un-keep negations,
  fail-fast, output contract. Full six-suite battery green (205 asserts).

### processors/rs-psstrip.ps1 — FrontMatter partition (consolidation 6c)

- **Partition at the parse boundary replaces the population-exclusion text
  guard** (psdig ast-primitives lineage restored — the design intent lost in
  the original transfer): new interior helper `_SplitCommentPopulation`
  splits Comment tokens into Native (feeds classification) and Derived
  FrontMatter objects (`SubKind` ScriptRequirements with spliced
  `$ast.ScriptRequirements` metadata, or Shebang). The text match happens
  exactly once, at the promotion site; classification carries zero
  frontmatter text predicates.
- **FrontMatter is a named sixth kind**: joins the classified list, has an
  explicit never-strip case in the ops switch (no op can select it), and is
  the first realization of the ontology's `frontmatter` kind. Run-folding
  now flushes on any non-LineComment kind — FrontMatter splits LineComment
  runs as stated policy, not as an emergent side effect.
- Interior helper permitted by the colonel AST validation fix (same-day) —
  compile + dispatch through a runspace pool verified. Envelope contract
  unchanged. Suite grows 68 → **79 asserts** (new section 13: maximal-ops
  preservation for both frontmatter species, spaced-`# Requires` /
  no-word-boundary / off-line-1 discriminators, run-split vs control pair,
  envelope stability). Regex fallback route untouched (pattern recognition
  is its legitimate job — unparseable files only).

### tests

- New: `crawler.tests.ps1` (27) · `pipeline.smoke.tests.ps1` (23 —
  harness-as-admiral, first end-to-end v3 pipeline run) ·
  `colonel-validation.tests.ps1` (12) ·
  `processors/tests/rs-attributes.tests.ps1` (34).
- `processors/tests/rs-psstrip.tests.ps1` extended 68 → 79 (FrontMatter
  partition semantics, section 13).
- **Legacy v1 harness retired** (consolidation 6b): `tests/colonel.tests.ps1`
  (targeted the removed rs.core.colonel.psm1 ApplyAll/KeyMatch/ResultMode
  API) deleted; dispatch-mechanics coverage rebuilt against v2 as
  `tests/colonel-dispatch.tests.ps1` (20 asserts: compile validation,
  index-stable ordering, Config delivery, serial≡parallel, _ChainHalt
  skip-for-item-only, per-item error capture with pre-step state, empty
  Items). Fix along the way: `Invoke-Plan -Items` gains
  `[AllowEmptyCollection()]` — Mandatory alone rejected `@()` at binding,
  making the intentional count-0 early-return unreachable for direct
  callers. `tests/colonel-bench.ps1` flagged stale (v1-era paths) — refresh
  deferred until perf work matters.
- **Broken-reference sweep (TODO item 1) executed.** Correction to the note
  above: `format.ps1` was never *removed* — it never existed in this repo
  (git: no commit ever touched it, nor `rs.core.colonel.psm1`). Both are
  PowerShellCore-era names; the processor arrived renamed as
  `format-ws.ps1` in the initial commit (it still self-identifies as
  `Processor = 'format'`), and the v1-era harnesses carried the old paths
  across the copy. Sweep findings: `processors/tests/format.tests.ps1`
  retargeted `..\format.ps1` → `..\format-ws.ps1` — fully API-compatible,
  **29/29 green on first run** (the suite was dormant since the copy-over);
  `colonel-bench.ps1` remains the only file with stale live references
  (v1 module path, format.ps1 default, hardcoded PowerShellCore corpus
  path). All other hits are benign: numerics lineage docs, tp-perplexity's
  `threadparser-perplexity` identity string, and `tests/test-cases/*` which
  are stripping fixtures, not executed code.
- Known-stale: legacy `tests/colonel.tests.ps1` targets the retired
  `rs.core.colonel.psm1` (v1) path — refresh pending (consolidation plan).

## 2026-07-23 — rs.core.numerics consolidation

### rs.core.numerics.psm1 — new module, replaces rs.core.hash / rs.core.lsh / rs.core.measures

- **The three G1 placeholder modules are deleted.** They were empirically non-functional
  (FNV/Pearson overflow throws, dead rolling-hash surface via the class default-param trap,
  Levenshtein 2D comma-index throw, Hamming sign-bit infinite loop) — full defect inventory
  in `issues/v3/rs-core-numerics-cross-exam-20260723.md`, design in
  `issues/v3/rs.core.numerics-design.md`.
- **Demand-driven surface** (sharding + near-term thread-corpus): identity (`Get-PathHash`,
  `Get-ContentHash`, `Get-StreamHash` — SHA256 hex), signatures (`Get-SimHash` BM25-saturated
  with optional IDF corpus weighting via `Get-DocStats`, `Get-MinHashSignature`,
  `Get-JaccardEstimate`), measures (`Get-HammingDistance/-Similarity` — chunked, any-width
  sigs, BitOperations popcount; `Get-JaccardSimilarity/-Distance` — empty-set safe, J(∅,∅)=1;
  `Get-LevenshteinDistance/-Similarity` — two-row DP, explicit `-CaseInsensitive`;
  `Get-CosineSimilarity`).
- **Provenance**: SimHash/MinHash ported from mathdig `hashlib-new.ps1` (masked-uint64
  generation, composite snapshot `json-jsonl_20260424_022119`); pinned lineage vectors in
  tests guarantee bit-identical outputs. Classes are internal — function-only surface, no
  `using module` needed by consumers.
- **Masked-arithmetic law** documented in the module header (5 rules distilled from the
  cross-exam); `processors/tests/rs-numerics.tests.ps1` keeps the four G1 traps as
  permanent regressions (sign-bit Hamming runs under a 3 s hang guard).
- **rs.core.sharding.psm1**: two imports (hash + lsh) replaced by one (numerics); call
  sites unchanged (`Get-PathHash`, `Get-ContentHash -Content`, `Get-SimHash -Text`).
  SimHash values in shard metadata change generation — no compat burden, the G1 SimHash
  always threw so no metadata ever carried one.
- **Excluded by design** (stay in the snapshot inventory until demand exists): CTPH, TLSH,
  CDC/rolling-window chunking, Compare-WithMetric dispatcher, Manhattan/Chebyshev/Angular/
  Dice/PrimeFactor, Mahalanobis/KL/JS, PMI/co-occurrence/entropy family.

## 2026-04-22 — Crawler / ignore compiler decoupling (continued)

### rs.core.ignore.psm1 — IgnoreDefaults, sentinel aggregate, empty-sentinel short-circuit

- **`$IgnoreDefaults` parameter added to `New-IgnoreCompiler`**: `[string[]]`, defaults to
  `@('.snapshot/', '.git/', 'node_modules/')`. Prepended to `$IgnorePatterns` before pipeline entry.
  Visible and overridable — pass `@()` to suppress entirely. No hardcoded tiers; single param, consistent
  treatment. Combined list replaces the prior `$IgnorePatterns`-only injection at the root node.
- **`$SentinelIgnoreFiles` aggregate field added to `IgnoreCompiler` class**: `[List[PSCustomObject]]`,
  populated during the factory sentinel scan. Stores `@{ NodePath; Source; Globs }` for every sentinel
  file successfully read across all nodes. Accessible on the compiler instance for diagnostics after
  `Invoke()` completes without walking every node.
- **Aggregate exposed on factory return shape**: `New-IgnoreCompiler` now returns
  `@{ CompiledNodes; SentinelIgnoreFiles }` instead of a raw array. `CompiledNodes` is passed to
  `Invoke-IgnoreFilter -CompiledNodes`; `SentinelIgnoreFiles` is the flat cross-tree diagnostic list.
  **Downstream note**: any existing call passing `$compiled` directly to `Invoke-IgnoreFilter -CompiledNodes`
  must be updated to `$compiled.CompiledNodes`.
- **Empty `$SentinelFileNames` short-circuit**: `IgnoreFiles` stamp is now separated from the sentinel
  scan loop. All nodes always get `IgnoreFiles = [List[PSCustomObject]]::new()` (required by constructor).
  The file-reading, `$remainingFiles` rebuild, and `Files` mutation are gated behind
  `if ($SentinelFileNames.Count -gt 0)` — passing `@()` skips all I/O and no `Files` lists are touched.
- **Sentinel pruning from `Files`**: sentinels are removed from `$node.Files` in the same pass that
  reads them. They do not appear in snapshot output. On read failure the file is still pruned — consumed
  as a configuration candidate regardless of parse success.

## 2026-04-22 — Crawler / ignore compiler decoupling

### rs.core.crawler.psm1 — sentinel file concerns removed

- **`SentinelIgnoreFiles` field removed**: crawler no longer holds or reads ignore file names.
- **`ReadIgnoreFiles` method removed**: glob parsing and sentinel detection moved to ignore compiler.
- **`IgnoreFiles` property removed from node shape**: root and child nodes now carry only `NodePath`,
  `AbsolutePath`, `NodeDepth`, and `Files`. Crawler owns filesystem structure and file metadata only.
- **Constructor and factory cleaned up**: `sentinelIgnoreFileNames` param and all related stubs removed.
  `New-FileSystemCrawler` is now a single-param call.
- **All commented-out stubs removed**: transplant to ignore compiler is complete; no vestigial
  reference code remains.

### rs.core.ignore.psm1 — absorbs sentinel scan; constructor hardened

- **`using namespace System.IO` added**: required by `[Path]::GetFileName` and `[File]::ReadAllLines`
  in the sentinel scan.
- **`IgnoreCompiler` constructor made `hidden`**: enforces factory-only construction. Direct
  `[IgnoreCompiler]::new()` calls from outside the module are blocked at the language level.
- **Sentinel scan added to `New-IgnoreCompiler`**: after normalizing the crawler graph to `$flatNodes`,
  walks every node's `Files` list, matches filenames against `$SentinelFileNames`, reads and parses
  matching files (stripping blank lines and `#` comments), and stamps `IgnoreFiles = [List[PSCustomObject]]`
  on each node before passing to the constructor. Failures are non-fatal (`Write-Warning`).
- **`SentinelFileNames` parameter added to `New-IgnoreCompiler`**: `[string[]]`, defaults to
  `@('.gitignore', '.snapignore')`. Moves the default list from the crawler's removed factory param.
- **Vestigial `else` branch removed from constructor**: `IgnorePatterns` injection previously had a
  type-check + fallback array path. Sentinel scan always stamps a `List[PSCustomObject]`, so the
  `Insert(0, ...)` branch is always taken. Dead branch excised.
- **Input contract updated**: nodes no longer carry `IgnoreFiles` from the crawler. Contract now
  specifies `Files` only; `IgnoreFiles` is built internally by the sentinel scan.
- **Namespace references normalized**: `[IO.Path]` and `[System.IO.Path]` consolidated to `[Path]`
  throughout, consistent with the `using namespace System.IO` declaration.
- **Module synopsis corrected**: "Translate pipeline" → "Gather-Scatter pipeline" (Stage 4 name).
- **`Invoke-IgnoreFilter` description corrected**: stale `[IO.Path]::GetRelativePath()` reference
  updated to `[Path]::GetRelativePath()`.
- **"backward compat" label removed** from `Test-PathIgnored` comment — no releases, no external users.

## 2026-04-22 — V3 pipeline maturation: ingest, ignore filter, internals, colonel.v2

### rs.core.internals.psm1 — horizontal utility reframe

- **Import guidance updated**: rs.core.internals.psm1 is now explicitly documented as a horizontal
  utility designed to be imported by any pipeline member, not just the top-level
  orchestrator. Module-level header added: no domain logic, no rs.core dependencies,
  freely importable by any stage or caller. "Admiral's responsibility" framing removed
  from load-order notes across the pipeline.

### rs.core.ingest.psm1 — self-imports internals; simplified to colonel orchestration only

- **Self-imports internals**: `Import-Module "$PSScriptRoot/rs.core.internals.psm1" -Force`
  added at module scope. Eliminates fragile implicit load-order dependency. Any module
  that needs internals should follow the same pattern — import directly, don't duplicate
  or assume ambient availability.
- **Extension filtering and `MaxSizeBytes` removed**: both metadata gates moved upstream
  to `Invoke-IgnoreFilter`. `Invoke-Ingest` now owns only colonel orchestration (compile
  - dispatch). `$ingestOwn` trimmed to `@('FilteredGraph')`.
- **Graph normalization updated**: accepts `@{ Graph; Skipped }` shape from
  `Invoke-IgnoreFilter` and merges upstream `Skipped` entries into its own output.
  Back-compat: plain dictionary / flat array input still works.
- **Introduced** (same session): new pipeline stage between `Invoke-IgnoreFilter` and
  colonel. `Invoke-Ingest` declares only the one param it uniquely owns; all
  `Compile-Plan` / `Invoke-Plan` params surfaced via `DynamicParam` using
  `New-ForwardedParamDictionary`. Runtime routing partitions `$PSBoundParameters`
  by inspecting each colonel function's declared parameter set — no hardcoded
  forwarding lists.

### rs.core.ignore.psm1 — metadata pre-filtering in Invoke-IgnoreFilter

- **Size ceiling and extension blacklist moved here from ingest**: both filters applied
  inside `Invoke-IgnoreFilter` immediately after `RelativePath` stamping, before ignore
  regex evaluation and before branch pruning. Already holds per-file metadata; runs
  before any I/O — the earliest meaningful elimination point.
  - `Invoke-IgnoreFilter` gains `MaxSizeBytes` and `ExtensionBlacklist` params.
  - Return type changed from raw `Dictionary[string, PSCustomObject]` to
    `[PSCustomObject] @{ Graph; Skipped }`. `Skipped` carries `FileTooLarge` and
    `ExtensionBlacklisted` entries with typed metadata.
  - Pre-filter loop stamps `RelativePath`, checks size, checks extension — one pass,
    no extra I/O.
- **`$script:HardExtensionBlacklist` moved here**: replaces old `$FileExtBlacklist`
  stub. Expanded list: images, video/audio, archives, compiled binaries, documents,
  fonts, data/model blobs.

### rs.core.colonel.v2.psm1 — backtick cleanup

- All line-continuation backticks replaced. Cmdlet calls converted to splat style
  (`@budgetParams`, `@ceParams`, `@ipParams`); `.AddScript().AddArgument()...` chain
  replaced with intermediate `$cmd` variable and single chained call.

### processors/file-read.ps1 — \_ChainHalt on failure

- Both error paths (NUL/binary content and read exceptions) now stamp `_ChainHalt = $true`
  on the returned `PSCustomObject` in addition to `ReadError`. Downstream chain executor
  can short-circuit remaining processors without inspecting the error type.
- Shallow copy of `$Item` fields (`AbsolutePath`, `SizeBytes`, `RelativePath`, `NodePath`)
  taken up-front — result is always a clean object regardless of exit path.

### processors/format.psm1 → format-ws.psm1

- Renamed. No stale references found in the workspace — no cascading changes.

### Architecture decisions settled

- Profile-based glob routing stays inside colonel (`Compile-Plan` / `Invoke-Plan`)
  — not abstracted to the caller.
- Post-ignore eligibility filtering is a discrete pipeline stage (ingest), not ad-hoc
  caller code.
- `rs.core.internals.psm1` is the canonical home for pipeline horizontal utilities;
  pipeline members import it directly rather than duplicating or relying on ambient load order.

## 2026-04-10 — tests/ — colonel-bench.ps1 generalized + test-cases added

- **`colonel-bench.ps1` moved** from `rs.core/colonel/` into `rs.core/tests/`
  alongside `colonel.tests.ps1`.
- **`colonel-bench.ps1` rewritten as general-purpose bench**: hardcoded stroll-corpus
  and `format` processor replaced with params `-CorpusPath`, `-Filter`, `-Processor`,
  `-ProcessorPath`, `-FileCounts`, `-InitIterations`, `-RunIterations`, `-TestName`,
  `-Export`. Default values preserve original behaviour.
- **`-Export` flag** writes processed output to
  `tests/results-temp/{callerScript}_{testName}_{timestamp}/`.
- **`tests/test-cases/`** added — integration fixtures: `ps.core-import-scratch.ps1`
  (parseable) and `ps.core-import-scratch-error.ps1` (missing final `}` — triggers
  `rs-psstrip` regex fallback).
- **`colonel.tests.ps1`** — stale `tp-generic.ps1` processor path corrected to
  `format.ps1`.
- **`project-map.txt` updated**: `colonel-bench.ps1`, `test-cases/`, `results-temp/`
  added under `tests/`.

## 2026-04-10 — project-map.txt + colonel/TODO.md

- **`project-map.txt` updated**: `rs-indent.ps1` and `rs-indent.tests.ps1` added.
- **`colonel/TODO.md` updated**: `rs-indent.ps1` checked off; bracket-access fix
  item added for `rs-psstrip.ps1` and `format.ps1`.

## 2026-04-09 — conventions and project map

- **`project.txt` renamed to `project-map.txt`** — name better reflects its role
  as a navigational file map rather than a generic project document.
- **`project-map.txt` updated**: `tp-generic.ps1` → `format.ps1`, self-reference
  updated.
- **`CONTRIBUTING.md` updated**: all `project.txt` references updated to
  `project-map.txt`; processor naming convention section added (no-prefix =
  pipeline-agnostic; `rs-` = RS-scoped; `tp-` = TP-scoped; prefix tracks pipeline
  scope, not language specificity).

## 2026-04-09 — project organization

- **`project.txt` introduced** at `rs.core/` root — diagrammatic layout of the
  operational module surface. Only operational items are listed; unlisted folders
  are implicitly non-canonical (archival, discussion, wip, etc.).
- **`tests/` folder introduced** — module-level test harnesses live here, adjacent
  to the module files they test (`colonel.tests.ps1` as first entry).
- **`processors/tests/` folder introduced** — processor unit tests scoped to the
  processors folder by locality (`rs-psstrip.tests.ps1`, `tp-generic.tests.ps1`).
- **`CONTRIBUTING.md` introduced** — covers project layout, processor contract
  (ISS-load-safe rules), test harness conventions, runspace hygiene, module conventions,
  and changelog convention. Closing ceremony documents the commit-and-record workflow.
- **Locality-based changelog convention established** — each operational folder
  carries its own `CHANGELOG.md` rather than rolling everything into the root log.
  Folder-specific changes are recorded in the nearest changelog; the root changelog
  records structural / cross-cutting decisions like this one.
- **Changelog convention amended** (per CONTRIBUTING.md) — test harnesses roll up to
  their parent folder's changelog rather than maintaining separate test-folder changelogs.
  Active changelogs: `rs.core/CHANGELOG.md` (this file), `processors/CHANGELOG.md`.

## 2026-04-09 — rs.core.colonel.psm1 + processors — cleanup and consistency pass

- **`IssPreset` enum renamed**: `Minimal→Bare`, `Standard→Full`. `Bare` maps to
  `CreateEmpty`, `Core` to `CreateDefault2`, `Full` to `CreateDefault`. All docstrings
  and examples updated to match.
- **`ResultMode` enum**: members now carry inline descriptions. String comparisons
  (`'Ordered'`, `'Unordered'`) in the serial branch replaced with typed
  `[ResultMode]::Ordered` / `[ResultMode]::Unordered` comparisons.
- **`$selectorProperty` rename**: `$key` parameter renamed throughout `RunCore`,
  `RunCoreSerial`, and `RunCoreParallel` signatures and bodies for clarity.
- **`$fnMapRef` removed**: `$this.ProcessorManifest` inlined directly at the
  `AddArgument()` call site in `RunCoreParallel`; intermediate reference variable gone.
- **Config clone fixed**: `$this.Config = $this.Config?.Clone()` in `Run()` was mutating
  manager state on every call. Replaced with a local `$configForRun` variable threaded
  through all dispatch signatures. `$this.Config` is never mutated.
- **Vestigial comments removed**: stale aspirational comments (`# set for deprecation`,
  `# ResultMode should be a first-class enum`, etc.) removed. `BuildIss()` carries an
  accurate `# FUTURE:` note about a CreateEmpty-based ISS planner.
- **Runspace boundary tags**: `# >> RUNSPACE BOUNDARY` tags added at the bootstrap
  reader and parallel worker `AddScript` call sites. Canonical explanation of
  `using namespace` parse-time scoping added to `.NOTES` in the class docstring.
- **Unified error attribution**: all error messages in both serial and parallel paths
  now use the `"Item [N]: <msg>"` prefix. Serial path previously used `"Serial item [N]:"`.
  Parallel worker now clears `$Error` before each processor call and checks `$Error.Count`
  after, so non-terminating (Write-Error) errors from processors are attributed per-item
  via `$errBag` rather than as a per-slice `"Worker error:"` at EndInvoke.
- **`rs-psstrip.ps1`**: `[CmdletBinding()]` and `[Parameter(Mandatory)]` removed — these
  caused `ParameterBindingException` in non-interactive ISS worker contexts. Config
  resolution migrated from 5 boolean fields to an `Operations` string array
  (`@('block-comments','doc-strings','comment-blocks','line-comments')` by default),
  matching the `tp-generic.ps1` pattern. Both early-return paths return
  `Operations = @($ops)`. Docstring updated throughout.
- **`tp-generic.ps1`**: docstring references to `Standard`/`Minimal` updated to
  `Full`/`Bare`.

## 2026-04-08 — rs.core.colonel.psm1 + processors — initial processor work

- **`ResultMode` enum** (Ordered/Unordered/None) introduced at module level.
  Parallel worker `$shared` hashtable was already removed (2026-04-06); this
  enum formalises the result-collection contract.
- **`[System.Collections.Concurrent.ConcurrentBag[string]]` fully-qualified** in
  the parallel worker `param` block. The short alias `[ConcurrentBag[string]]`
  (from `using namespace System.Collections.Concurrent`) is parse-time /
  module-scope and is not available inside `AddScript()` worker contexts.
- **`rs-psstrip.ps1` initial implementation** — AST-based PowerShell comment
  stripper. Five comment kinds: BlockComment (top-level `<#..#>`), DocString
  (`<#..#>` inside function/class body), CommentBlock (contiguous 2+ `#` lines),
  LineComment (standalone `#` line), InlineComment (`#` with preceding code).
  Span reconstruction uses character offsets with leading-whitespace and
  trailing-newline consumption to avoid blank-line artifacts. Config via boolean
  toggle keys (StripBlockComments, StripDocStrings, …) — migrated to Operations
  array in 2026-04-09.
- **`tp-generic.ps1`**: `[Parameter(Mandatory)]` removed from Item parameter;
  `[CmdletBinding()]` commented out. Neither attribute is ISS-worker-safe.
  Processor self-documentation block added to docstring.

## 2026-04-06 — rs.core.colonel.psm1 — bugfix

- **`$iss` local variable renamed to `$issState` in `BuildIss()`** — `$iss` collides
  case-insensitively with the class property `$this.Iss` under `Set-StrictMode -Version Latest`
  in PS 7.6+, causing a parser error on import. Gotcha: local variable names inside class
  methods must not case-insensitively match any class property name.

## 2026-04-06 — rs.core.colonel.psm1 — RunMode unification

- **`RunMode` enum** (ApplyAll/KeyMatch) introduced at module level.
  `ApplyAll` broadcasts one processor key to all items (existing behaviour).
  `KeyMatch` resolves the processor key per item from a named property on the item
  object — enables mixed-format post-processing batches without grouped dispatch.
- **`RunCore` / `RunCoreSerial` / `RunCoreParallel`** replace the former `RunSerial`
  and `RunStaticByFunction` hidden methods. Serial-vs-parallel is one axis inside a
  single unified implementation; dispatch mode (ApplyAll/KeyMatch) is the orthogonal
  axis. Both branches share the same fn-resolution logic.
- **`Run([object[]]$items, [RunMode]$mode, [string]$key)`** explicit overload added.
  Existing `Run([object[]]$items, [string]$processorKey)` shorthand retained as an
  ApplyAll delegate — no call-site breakage.
- **`$shared` synchronized hashtable removed** from the parallel branch. Workers now
  write results directly to the pre-allocated `$this.OrderedOutput` array by index
  (distinct-index concurrent writes to a .NET reference-type array are safe) and
  errors directly to `$this.Errors` (ConcurrentBag[string]).
- **`MaterializeMs` timing phase removed** — no post-pass needed without `$shared`.
- **`AssertProcessorFunctionLoaded` removed** — redundant post-ISS-load validation;
  any real ISS failure surfaces on the first worker error.
- **`ResolveProcessorFunction` removed** — inlined as a direct
  `ProcessorManifest.ContainsKey` check in `RunCore`.
- **`PoolOpenMs` timing** moved inside `RunCoreParallel` with a dedicated stopwatch
  (previously measured in `Run()` before the pool-open call).
- **Return envelope**: `DispatchMode` field added; `Function` field removed (was the
  resolved fn name for ApplyAll; derivable from manifest if needed). `SerialMs` timing
  key removed — `SerialRunspaceOpenMs` + `SerialProcessMs` sub-keys cover the serial
  path fully; `TotalMs` covers the outer span.

## 2026-04-05 — rs.core.colonel.psm1 and some reorg

- moved `rs.core.colonel` to `ps.core.reposnapshot/rs.core` along with the benchmark script and this changelog and the processors subfolder with runspace ps1 scripts
- created .feedback folder for feedback threads
- moved the rest of threadparser to rs.core under rs.core/threadparser

## 2026-04-05 — rs.core.colonel.psm1

- **`IssPreset` enum** (Minimal/Core/Standard) introduced. All ISS construction
  centralised in `BuildIss()`; no direct `CreateDefault*` / `CreateEmpty` calls
  exist outside that method.
- **`SetIssPreset([IssPreset])`** and **`SetIssModules([string[]])`** fluent setters
  added. `IssModules` pre-loads PS modules into every worker runspace alongside
  processor functions.
- **Serial fast-path** (`RunSerial`): when graded worker budget resolves to 1 thread,
  a single lightweight runspace is opened instead of a pool (~3ms vs ~300ms
  steady-state open cost). `Run()` branches on `budget.Threads == 1`; no pool
  is created on that path.
- **Timing granularity**: `SerialRunspaceOpenMs` and `SerialProcessMs` added inside
  `RunSerial`; `SerialMs` was the total on the `Run()` caller side
  _(removed in 2026-04-06 — `TotalMs` covers the outer span)._
- **Lazy `SystemCores`**: WMI (`Get-CimInstance Win32_Processor`) deferred to first
  `ResolveWorkerBudget` call; construction no longer fires WMI.
- **PSOne-style parallel manifest bootstrap**: `LoadProcessorsFromManifest` refactored
  into Phase 1 (concurrent raw PS fan-out, capped at `InitThreads`) and Phase 2
  (serial ISS construction — `InitialSessionState` is not thread-safe). Resolves the
  bootstrap catch-22: colonel cannot use its own Tau/K machinery before the ISS exists.
- **`SetInitThreads([int])`** fluent setter added for bootstrap concurrency cap (default 4).
- Docstring overhauled: `.SYNOPSIS`, `.DESCRIPTION`, `.FLUENT SETTERS`, revised examples
  covering current API surface including new ISS setters.

## 2026-04-01 — Factory method

- renamed `ps.core.hpc` to `rs.core.colonel`
- Renamed class to RunspaceManager
- Refactored user-facing parameters, introduced new names MaxCoresAllowed NumCoresReservedcollectresults is set to false
- Deprecated custom threads mode and customthreads number, it was redundant and introduced unnecessary complexity
- removed SafeMode and inserted a warning to log in its place

## 2026-04-01 — Factory method removal

- Removed static factory methods `ForContentProcessing()`, `ForFileProcessing()`, `ForBulkProcessing()` from the class.
- Removed wrapper functions `New-ContentProcessor`, `New-FileProcessor`, `New-BulkProcessor` and their exports.
- Sole export is now `New-ParallelismEngine`; the `ParallelismEngine` class is auto-available on import.

Rationale: the factory presets were thin sugar over two-call fluent chains and covered only 3 of 12+ pattern/threading combinations. Callers already need to understand the primitives to choose a preset, so the indirection added no value. The fluent API is the intended configuration surface.

## 2026-04-01 — Architecture remediation pass

Bug fixes:

- Fixed Cascade/Reducer double-invocation: `& $this.CascadeScript.Invoke(...)` was calling the scriptblock twice (once via `.Invoke()`, once via `&`). Changed to `& $this.CascadeScript $results $this.Config`. Same fix applied to Reducer.
- Fixed `RunQueue` silent exception swallowing: `$ps.EndInvoke($ps._async) | Out-Null` discarded all terminating errors from queue workers. Wrapped in `try/catch` with errors appended to `$this.Errors`. ForEach and Static already had this; Queue was the outlier.
- Added 50ms floor to `WaitAllHandles` per-handle timeout (`[Math]::Max(50, ...)`) to prevent cliff-edge zero-timeout polling when an early handle consumes the bulk of the timeout budget.

Dead code removal:

- Removed `$safe` parameter from `RunForEach` and `RunStatic` inner scriptblock `param()` blocks and corresponding `.AddArgument($this.SafeMode)` calls. SafeMode enforcement already happens on the main thread at the top of `Run()`.
- Removed `WriteGate` (`ReaderWriterLockSlim`) property, `_Init` allocation, `InvokeWithWriteLock()` method, and `Dispose()` cleanup. Never called; `ConcurrentBag` handles all thread-safe collection.
- Removed `UseArrayCollector` property, `EnableArrayCollector()` fluent setter, and the O(n²) branch in `GetResults()` that used `$arr = @(); $arr += $x` with a misleading comment about "7.5.2's fast +=". Collapsed `GetResults()` to a single `return $this.Collector.ToArray()` path.

Performance:

- Replaced `$handles = @()` / `$handles += ...` with `List<WaitHandle>` and `.Add()` in all three execution patterns. Same for `$collectors` and `$workers`. Eliminates O(n²) array reallocation on accumulation.
- Replaced `RunStatic` slice building from `$slices[$t] = @(); $slices[$t] += ...` to `List<object>[]` with `.ToArray()` at the end.
- Replaced `(Get-Date).ToString('o')` with `[DateTime]::UtcNow.ToString('o')` in `WriteTrace`.

Documentation:

- Added `ConcurrentBag<T>` non-deterministic ordering note to module header and `GetResults()` method comment.
- Updated module synopsis to remove stale references to 7.5.2 array consolidation and 7.5.3 serialization.
- Updated trace format string to remove `arrayCollector` placeholder.

Sources: cross-examination of Gemini Deep Research report, Comet architecture review, and Comet revisions thread. Gemini correctly identified the EndInvoke swallowing, dead `$safe` param, dead WriteGate, and WaitAllHandles cliff-edge (though prescribed the wrong fix for the latter — `WaitHandle.WaitAll()` regresses the STA-safety fix already in the code). Comet caught the Cascade/Reducer double-invocation bug that Gemini missed entirely, correctly rebuffed the WaitAll regression, and identified the `ConcurrentBag` ordering concern. The `UseArrayCollector` O(n²) bug and `+=` remediation across all patterns were consensus findings from both.

## 2026-03-31 — Additional cleanup

- renamed `threadparser/v2-new/pwshspc.core.hpc.psm1` to `ps.core.hpc.psm1` to eliminate confusion
- bumped required powershell to 7.5.3
- removed 7.3 enforcement
- removed references to deprecated serialization from pwshspc original source
- updated formatting of module exports to use array @(..)

## 2026-03-31 — CliXml cleanup

- Removed `Serialization` configuration property and `SetSerialization()` fluent API.
- Deleted `SerializeWorkItem()` helper and all `ConvertTo-CliXml`/`ConvertFrom-CliXml` branches.
- Simplified worker scriptblock `param()` lists and `.AddArgument()` calls to remove serialization arguments.
- Updated run-time trace message to remove serialization placeholder.

Rationale: this forked copy under `threadparser/v2-new` does not require the CliXml serialization paths (they were gated behind a non-default option). Removing them keeps the module compatible with the declared `#Requires -Version 7.3`, reduces complexity, and avoids referencing PS 7.5-only serialization behavior.

Notes:

- These changes are localized to the `spc.core.hpc.psm1` copy in `v2-new` and do not affect other repositories.
- If you want a brief compatibility note included in a module manifest or README, I can add it.

## 2026-03-31 — Additional cleanup

- renamed `threadparser/v2-new/pwshspc.core.hpc.psm1` to `ps.core.hpc.psm1` to eliminate confusion
- bumped required powershell to 7.5.3
- removed 7.3 enforcement
- removed references to deprecated serialization from pwshspc original source
- updated formatting of module exports to use array @(..)

## 2026-03-31 — CliXml cleanup

- Removed `Serialization` configuration property and `SetSerialization()` fluent API.
- Deleted `SerializeWorkItem()` helper and all `ConvertTo-CliXml`/`ConvertFrom-CliXml` branches.
- Simplified worker scriptblock `param()` lists and `.AddArgument()` calls to remove serialization arguments.
- Updated run-time trace message to remove serialization placeholder.

Rationale: this forked copy under `threadparser/v2-new` does not require the CliXml serialization paths (they were gated behind a non-default option). Removing them keeps the module compatible with the declared `#Requires -Version 7.3`, reduces complexity, and avoids referencing PS 7.5-only serialization behavior.

Notes:

- These changes are localized to the `spc.core.hpc.psm1` copy in `v2-new` and do not affect other repositories.
- If you want a brief compatibility note included in a module manifest or README, I can add it.
