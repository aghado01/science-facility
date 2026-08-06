# Custom shard row format — observed design elements (name pending)

**Status:** description of current LTS output · **Filed:** 2026-07-22

The LTS sharded snapshot payload is not JSON/JSONL — it is a custom line-oriented
record format, a deliberate hybrid of CSV, JSONL, and length-prefixed (LPAC-style)
containers, optimized for LLM/agent consumption.

## Row grammar

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
- **Selective encoding (deliberate feature)**: certain characters are intentionally
  encoded — notably newlines as `\n` — so line breaks are *explicit and consistent* in
  serialized code (reader clarity) and each record stays on one line. This is to keep,
  not to shed. Overall escape bloat is much reduced relative to the full JSON/JSONL
  escape regime the format replaced — reduced, not zero.
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
