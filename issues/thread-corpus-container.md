# Thread-corpus JSONL container (track 3 — scoping)

**Status:** scoping · **Filed:** 2026-07-22

## Track map (user, 2026-07-22)

Three distinct tracks with different design intents and rules — the virtual-DB concept
(entry-point manifest, byte-offset seek, controlled-chunk retrieval) transfers; the
containers and processing rules diverge:

1. **Code ingestion** — current focus; mature through v3. Markdown/config files
   (json/jsonl/yaml, docs) are *not wanted* in code snapshots — a custom side-car
   container is planned for those (TODO: "different output channel/format").
2. **Structured docs / markdown** — barely touched; document-type-specific markdown
   processors; similar to code processing in some ways, different in others.
3. **Chat-thread corpora** (this brief) — near-term interest: ingest large corpora of
   chat-thread exports into a **JSONL container** agents can selectively
   seek/review/retrieve in controlled chunks.

AST subaddressing of code files: not an immediate priority.

## Unit model

- **Row = ExchangeBlock** (MarkPig envelope): prompt + reply (+ citations) — the
  composite legible unit; exchanges are the chunks-in-reading-order.
- **Thread = TranscriptBlock**: ordered exchanges + thread metadata (source flavor,
  title/slug, export date, source path, content hash).
- **Corpus** = collection of threads + corpus manifest.

## Container sketch — store vs view (refined 2026-07-22)

- **Store = JSONL + `.jidx` side-car** (jso-jackson `[JsonlIndex]::Build` binary seek
  index): one exchange per row; the system of record for the corpus. Search and
  deduplication mechanisms operate here. Compatible with existing jso-jackson
  investigation tooling out of the box.
- **Planned fold-in (user, 2026-07-23): the jso-jackson primitives become the store's
  access/maintenance layer** — `[JsonlTraversal]` path navigation, `[JsonlIndex]`/.jidx
  seek indexing, `Utf8JsonWriter`-based record extraction (no PSCustomObject
  round-trip, no format loss) — for reading, investigating, AND maintaining large
  JSONL datasets. This graduates jso-jackson from ad-hoc investigation tooling to
  store infrastructure: corpora become efficiently accessible with structure and
  tooling.
- **View = rendered consumption artifacts** for LLM readers — the custom
  length-prefixed format and/or corpus manifest (the `*_tree.md` analog): threads →
  exchange index with per-row byte offsets (UTF-8-accurate, `Get-EntryByteOffsets`
  pattern) so agents seek without scanning. Extension naming of views considers RTE
  sniffing (shard-format-notes.md).
- **Operational/metacognitive guidance is first-class**: the manifest's instruction
  block (rs.core.template instruction-set pattern) ships with the payload.

## What already exists

- `reposnapshot-v3/processors/tp-perplexity.ps1` — Perplexity flavor parser → Exchange
  objects (Index/Prompt/Reply/Citations); the mask→segment→restore architecture is the
  template for other flavors.
- `reposnapshot-v3/rs.core.sharding.psm1` — **re-dispositioned**: the v3.1 JSONL/piped
  generation (Write/Read-JSONLShard with offset+count, Build-ShardMetadata TOC,
  manifest, Get-FileFromShard) is the natural substrate for THIS track, not vestigial
  code-track machinery. (Caveat: Build-ShardMetadata calls SimHash/broken LSH — flag
  off or bind Hashish.)
- `RepoSnapshotLts.psm1` `Get-EntryByteOffsets` — byte-accurate row addressing to port.
- Hashing for dedup / near-dup thread detection: consolidate the corrected
  **PowerShell equivalents** (mathdig `hashlib-new.ps1` masked-uint64 patterns) —
  this is not a C# project; the hashish/.cs successors are study/reference material
  for the eventual centralization, not a binding. Do not use rs.core.hash/lsh as-is
  (broken numerics).
- Prior art in PowerShellCore: `rs.core/threadparser` (.legacy Markdig parser),
  NDPSON doc-ingestion discussions under `rs.core/.discussion/sharding/`.

## Open decisions

1. Row schema: flat exchange rows with thread-id keys vs thread-header rows + exchange
   rows; where thread metadata lives.
2. Layout: one JSONL per thread, sharded corpus files, or thread files + corpus index.
3. Long-reply secondary chunking (code fences as opaque regions; reply sections) —
   likely deferred until a real corpus demands it.
4. Flavor coverage: perplexity first; claude/chatgpt/gemini export flavors next;
   flavor detection vs explicit configuration.
5. Citation/footnote normalization across flavors.
6. Orchestration: colonel fits naturally (items = thread files, chain = tp-{flavor});
   requires the colonel helper-function contract fix (tp-perplexity currently rejected
   for `function _MaskByRegex`).
7. Naming (user's Latin-slug brand; MarkPig envelope relationship).

## Suggested first milestone

tp-perplexity → JSONL end-to-end over a small sample corpus: crawl a folder of exports
→ parse to Exchanges → write corpus manifest + JSONL rows + byte offsets → verify the
agent-seek round trip (fetch exchange N of thread T by offsets alone, no scan).

**Candidate first corpus:** the ps.core.pwshspc markbrain historical docs — the
Gemini "compiled kernel" report and the Perplexity/other digestion threads around the
pwshspc → ThermoMapper pivot. A decision-point archive whose retrieval value is
exactly the track's promise ("when did I decide this, on what evidence, which model
said what"), multi-flavor, modestly sized, personally meaningful — ideal dogfood.

## Work log

_(append findings/results here)_
