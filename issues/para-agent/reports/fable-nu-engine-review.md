Let me have a look at what's landed — the new report and the para-agent MCP itself.

The report gives the big picture — let me look at the actual source to ground my take.

Now the tool surface and adapter engine:

Good picture now. Let me empirically verify two suspicions against the pinned `nu` binary before I give you my take.

Both suspicions confirmed. One quick check on the schema:

I've read the report and the whole `src/` layer, and ran the pinned `nu.exe` against a couple of suspicions. Here's my take.

## The apples are good apples — the architecture is the strongest para-agent has been

The core moves are genuinely right, and they compound well together:

- **The mediation-level transcript is the correct ontological choice.** Neither native transcript is yours to own; the exchange envelope (prompt → records[] → terminal reply) is. Row-0 header + append-only exchange rows is the same shape that's worked in jso-jackson/reposnapshot land, so your existing tooling (`Get-JsonlSchema`) composes for free.
- **The reply + receipt split is a real context-economy win.** Level 0/1 by default, `scrutinize` for levels 2/3 — that's exactly the progressive-disclosure discipline you keep asking for, enforced structurally rather than by prompt exhortation.
- **Declarative adapters as data, not code** ([adapters.js](mcp/para-agent/src/adapters.js) + `adapters/*.json`) keeps the engine free of vendor branching, and the heuristic fallback means an unmapped client degrades gracefully instead of exploding.
- **Pinned `nu` 0.114.1 + profile isolation** ([profiles.js](mcp/para-agent/src/profiles.js)) is clean — the backend profile keeps queries deterministic regardless of what the user's ambient nu config looks like.

## But the new nu scrutiny path has two confirmed bugs that cascade into each other

**1. The NuEngine error envelope is invalid JSON, so error detection is dead code.** In [nu.js:28](mcp/para-agent/src/nu.js:28), the catch branch emits `$"{'__nu_error__': '($err.msg)'}"`. I ran it against the pinned binary — output is `{'__nu_error__': 'Cannot find column 'b''}`. Single-quoted keys aren't JSON, and the unescaped inner quotes make it worse, so `JSON.parse` throws, the `parsed.__nu_error__` reject branch at line 51 never fires, and the caller receives the garbled error string as if it were successful data. It should be `{__nu_error__: $err.msg} | to json`.

**2. The default `scrutinize` path (no `xid`) queries a column that's never persisted.** The summary pipeline at [index.js:735](mcp/para-agent/src/index.js:735) does `select ... duration_ms ...`, but `duration_ms` only exists in the ephemeral receipt ([assembler.js:145](mcp/para-agent/src/assembler.js:145)) — it's never written into the committed exchange row. Verified against nu 0.114.1: `select` on a missing column hard-errors (`column_not_found`). So the exchange-listing mode — the entry point to the whole disclosure ladder — fails on every call, and because of bug 1, it fails by returning a pseudo-JSON error string dressed as data rather than a clean rejection. Fix is either persisting `duration_ms` in the row or using `duration_ms?` / dropping it from the select.

**Related: the report's Verification Summary cites `test_transcript_pipeline.js`, and that file doesn't exist anywhere in the repo.** No `test/` or `tests/` directory at all under `mcp/para-agent/`. Given bug 2 breaks the default scrutinize invocation, whatever ran during development either didn't exercise the no-xid path or was scratch that never got committed. This is the false-green pattern again — a verification claim in the doc with nothing checkable behind it.

## Smaller flags, in descending order of interest

- **`_countExchanges` counts by substring** ([transcript.js:109](mcp/para-agent/src/transcript.js:109)): any record _body_ containing the literal `"record_type":"transcript_exchange"` inflates the count. In this ecosystem that's not exotic — a para agent whose tool output includes reading a transcript file is exactly the self-ingestion double-vision case, and a wrong count shifts `exchange_index` for all subsequent rows.
- **`crypto` is used but never imported in adapters.js** (`crypto.randomUUID()` at line 82 etc.). The global exists on Node ≥19; on Node 18 it's flag-gated, and `package.json` declares `engines: >=18`. Either import it or bump the floor to 20.
- **`xid` is string-interpolated into nu pipelines** in `scrutinize`. Server-generated xids make it low-risk today, but the pattern will bite the first time a handle or id can carry a quote. The base64 input trick in `eval` shows you already know the safe pattern — worth using it for parameters too.
- **`xidx` can duplicate under concurrency**: `nextIndex` only increments on commit, so two in-flight assemblers on the same transcript get the same index. Fine as long as exchanges are strictly serial per session — but nothing enforces that.
- The report's "transactional atomic commit" language slightly oversells a single `fs.appendFile` — it's fine as single-writer-per-session-file, but the doc should say that's the invariant it depends on rather than implying stronger guarantees.

Net: the design layer is in the best shape it's ever been — the schema hierarchy, adapter symmetry, and disclosure ladder are keepers. The execution substrate is one careful pass away from trustworthy: fix the error envelope first (it's the bug that hides every other bug), then the `duration_ms` select, then decide what real test coverage looks like so the report's verification section describes something that exists. Happy to do that pass if you want it.
