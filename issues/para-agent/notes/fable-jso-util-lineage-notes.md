Fun direction — before I weigh in, let me actually look at what `jso-jackson` and `jsonl_engine` do today, and load the nu skill so I'm not hand-waving about what nu gives you natively.

The nu skill and both codebases are in context now. Quick empirical check of what the installed nu actually does with JSONL before I make claims about it:

Verified enough to ground this properly. Here's my read, with the empirical bits first since they shape the whole answer.

## What installed nu (0.114.1) actually gives you

- `open file.jsonl` returns a raw **byte stream** — no auto-parse for the `.jsonl` extension in this version. The idiom is `open --raw file.jsonl | from json --objects`, which yields `table<...> (stream)` — genuinely streaming, not slurped.
- Optional cell-paths handle ragged records well: `where message?.id? != null` worked across records that lack `message` entirely.
- `columns` gives the union of keys; `histogram type` is a one-word value-distribution (columns named `type`, `count`, `quantile`, `percentage`).
- Two gotchas surfaced immediately: `describe` reported the schema as `table<type: string, n: int>` — it silently omitted `message`, which two of three records have. And a bare `select` on ragged data errors until you spell fields optionally. Nu makes raggedness _survivable_, but it has no concept of **coverage** — which is exactly what `Format-JsonlSchema`'s percentages exist for.
- No polars plugin installed, so there's currently no lazy-dataframe story for GB-scale files — relevant below.

## The clean split that falls out

Looking at jso-jackson's function inventory against nu's vocabulary, the ideas partition sharply:

| jso-jackson idea                                                                             | Fate in a nu world                                                                                      |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| counts, value distributions, declarative conditions, path select, duplicate scan             | **Dissolves into nu idioms** — `length`, `histogram`, `where a? == x and b? != null`, `get`, `group-by` |
| schema **with coverage %**, schema drift compare                                             | Survives — nu has `columns`/`describe` but no coverage concept                                          |
| `.jidx` seek index, hash sidecars, Bloom filters, byte-offset preview windows                | Survives — **cannot** live in nu's parsed world                                                         |
| RPC artifact discipline (probes-first, results-to-file, `{path, rowCount, preview}` returns) | Survives — becomes MCP **tool contracts** instead of README prose                                       |

The deep reason for the second half of that table: nu's data model erases bytes at the parse boundary. Once a line becomes a record, the original offsets, spans, encoding, and EOL are gone, and `to json` won't round-trip byte-identically. Everything jsonl_engine is _about_ — the `Codec`/`Eol` policy axes, the CRLF/unicode golden fixtures, `test_byte_equality`, signed prefixes, the Complete/Signed/Physical bounded views, the append transaction — lives below that boundary and has to stay in a byte-owning engine. Nu can be the _expression layer_ over that engine; it can never _be_ that engine. (And per your standing byte-semantics note: whatever the successor is, its API should name SizeBytes vs SpanBytes vs row-length distinctly from day one.)

## Why nu+TypeScript is actually a strong pairing here

The alignment I find most satisfying: jsonl_engine's framed CLI protocol — one compact UTF-8 JSON value frame per stdout line — **is nu's native ingestion format**. The PowerShell client needed real machinery to cross that boundary: `NullString` carriers so JSON null survives the pipeline, `-AsHashtable` for case-distinct keys, frame-to-PSCustomObject conversion. In nu, `| from json --objects` _is_ the client's value layer; null is a first-class value and records preserve keys. The hard-won parts of the PS client that remain worth keeping are the protocol _discipline_ — sequence-gap detection, buffer-until-clean-exit, structured stderr errors — and that's a thin wrapper, not a conversion layer.

So the generational architecture I'd sketch:

- **TS engine core** (the jsonl_engine role, generic parts only): byte-owning store operations — offsets/spans, `.jidx` build and seek, hash sidecars, `.sig`/bounded views, strict validation, schema-with-coverage, ajv-backed schema checks. TypeScript earns its place because the MCP SDK is TS-native: one codebase, two surfaces — **MCP tools for agents, framed stdout verbs for shells**. Same verbs, same response shapes.
- **nu module** (the jso-jackson ergonomic role): custom commands (`jso count`, `jso schema`, `jso find …`) that invoke engine verbs and land frames as native tables, with `explore` for interactive digs. Cheap probes (histogram, where-chains) stay pure nu against engine-provided _windows_, so you never pay full-file reparse for the fifth probe of a session — that's what the seek index is for, and it also covers the missing big-file story without needing polars.
- **MCP contracts encode the README**: jso-jackson's usage guide is essentially a tool spec written as prose aimed at models — probes before dumps, capped distributions, results to files, return path + count + small preview. The successor makes that structural: the tool _can't_ dump 10k records because its response schema is `{resultPath, rowCount, preview[≤5]}`. Your `summary.json`/`request.json` RPC convention becomes the wire format rather than a convention agents must remember to follow.

## The scope caution

I'd resist porting jsonl_engine wholesale. Its v7-era invariants — the deposit transaction, reparse-point defenses, drift-rollback under lease, `ArticleManifest` semantics — are codex-scientiae _domain_ machinery, not generic data tooling, and they're battle-hardened where a rewrite would start from zero. The successor should take the generic read/probe/index/policy layer and leave publication in Python. Meaningful bridge option in the meantime: because the framed protocol is nu-native, a nu client module could speak to the **existing Python engine today** with maybe thirty lines — a low-cost proof that nu-as-client works, before any TS engine exists.

If you want, a natural next step is a brief in science-facility (sibling to `mcp/mdnav`, say) pinning down the capability split and the verb surface — which jso-jackson functions dissolve, which become engine verbs, what the MCP tool contracts return. Say the word and I'll draft it.
