# Decisions ledger

Running registry of **decisions and their reasons** — what was settled, why, and
what it would cost to reverse. Companion to `payload-manifest-ledger.md`, which
tracks declarations the *payload* owes a reader; this one tracks calls the
*project* has made.

Filed, not argued. Full rationale lives in the linked docs; this is the index
that stops a settled question being reopened from scratch, and stops a
deliberate exception being "fixed" by someone who reads it as an oversight.

Status vocabulary: `settled` · `leaning` (direction stated, not final) · `open` ·
`superseded`.

## Architecture and scope

| # | decision | why it is consequential | status | source |
|---|---|---|---|---|
| 1 | **No MCP built on v3.** Agent-facing tooling becomes a separate successor implementation (Node); the PowerShell tool stays CLI | Retires the "MCP is the only real decoder" rider wholesale. Codec totality loses its one planned operational consumer, which is what made the codec simplification safe rather than reckless | settled 2026-08-14 | shard-format-notes §Content codec; mcp-surface |
| 2 | **Finishing v3 is how the port gets specified.** Working the nuances out here means the Node successor inherits settled answers | Reframes v3 completion as spec work, not just shipping. Argues for simplicity at every fork: each exotic decision is one more thing to re-derive in another language | settled 2026-08-14 | this session |
| 3 | **LTS/v3 airgap is a full copy, not a shared reach.** `rs.lts.sharding` / `rs.lts.template` / `rs.lts.numerics` at root; LTS reaches into `reposnapshot-v3/` for nothing | The recommendation on file was a one-line cross-boundary path. User took the stronger separation deliberately — the point is that the two stop being entangled *before* the work starts, not that duplication is minimized. **The two numerics copies will diverge, and that is intended** | settled 2026-08-14 | v3-emission-extraction-swarm-plan |
| 4 | **`rs.core.numerics` is not dead code.** Its lack of importers under `reposnapshot-v3/` is a sequencing artifact | The code invites exactly the wrong inference — a module with zero importers in its own tree reads as vestigial. `rs.core.shards` will consume it (`Get-PathHash` for Flat ordering, content hashing for shard metadata) | settled 2026-08-14 | v3-emission-extraction-swarm-plan |
| 5 | **Emission extraction is not a swarm job.** The conceptual decomposition replaced the wave plan | LTS's emission carries structural inversions — row grammar written three times, offsets recovered rather than recorded, two grouping paths, buffer-everything, hardcoded manifest. A verbatim port imports all of them, then needs untangling. Stages need per-step judgment | settled 2026-08-14 | v3-emission-extraction-swarm-plan (CANCELLED header) |
| 6 | **A spec the code does not read has no teeth.** Vetoed a JSON character-policy store | It would be a second thing to maintain with a test babysitting it — two artifacts, one of which does no work. The character policy therefore lives in the test suite, *because the suite runs*. The Node port reads tests, not a document, which also buys behavioral equivalence rather than documentary agreement | settled 2026-08-15 | this session |

## Content codec

| # | decision | why it is consequential | status | source |
|---|---|---|---|---|
| 7 | **Round-trip is an ingestion ideal, not an artifact property.** Don't break code on the way in; byte-exact rehydration is not a goal | The premise under the whole codec simplification. Snapshots are one-way views regenerated on demand, not a currency for reconstructing source | settled 2026-08-14 | shard-format-notes §Posture |
| 8 | **`\` is never doubled.** No self-escape | Dissolves the invariant that separated backslash from codepoint substitution: `\` now only *adds* marks at line breaks instead of rewriting source characters, so the payload shows the source verbatim at ~1 token instead of 3. Cost is ambiguity at ~1.8 sites per shard (the measured 0.22% `\\` row) | settled 2026-08-14 | shard-format-notes §"Why rule 2 is the important one" |
| 9 | **EOLs normalize, not preserve.** Every terminator folds to `\n` | Resolved *against* the standing recommendation. Both its premises fell: losslessness has no consumer, and stage ownership was mis-drawn — encoding surviving line breaks is the container's job, distinct from `format-ws`'s job of folding CRLF within content | settled 2026-08-14 | shard-format-notes §"Open fork — CLOSED" |
| 10 | **Compaction is a notice, not a cipher key** | It no longer teaches decoding, because nothing decodes. It exists so a reader does not mistake the payload for byte-faithful | settled 2026-08-14 | payload-manifest-ledger #16 |
| 11 | **Bidi controls U+202A–U+202E / U+2066–U+2069 are NOT stripped.** Reported by a diagnostic step instead | Raised as a read-integrity gap on the Trojan Source threat model (source displays differently from how it executes) — **and that was overstated.** Bidi is a *presentation* algorithm (UAX #9): files store logical order, only a renderer reorders. A model reads the byte sequence in file order, which is the order the compiler sees, so the display/execute divergence needs a renderer in the path and there is none. The attack targets human review in an editor or diff. Rendering has no provenance in these artifacts (already settled for substitute glyphs). **It also inverts**: where bidi controls actually occur it is i18n resources and mixed RTL string literals, where they are load-bearing content — decision #15's category, not the strip list | settled 2026-08-15 | this session |
| 11b | Detection belongs to a **diagnostic processor step**, not to the whitespace stage — read-only tail, after all content mutation | Position class already exists (`rs-attributes`): enrich-only, runs after ALL content mutators, position is a profile invariant the processor stays ignorant of. Mechanism needs no new machinery — attach an element, assemble declares it via the open element model, the writer decides emission. That is how a diagnostic stays out of the payload without the processor knowing sidecars exist. Scoped in `briefs/charscan-diagnostic-brief.md` — narrow (bidi only), grown by accretion, filed as a side quest that does not block the e2e sprint | settled 2026-08-15 | charscan-diagnostic-brief |

## Whitespace processing

| # | decision | why it is consequential | status | source |
|---|---|---|---|---|
| 12 | **Defaults are the 99% case, deliberately aggressive** | The justification for the default op set is *what is wanted almost always*, not a per-op risk argument. Reading the defaults as conservative-by-design would be backwards | settled 2026-08-15 | this session |
| 13 | **Trailing-whitespace trimming is an accepted exception, not an oversight.** It can repair a broken C line-continuation, changing what the code means | Explicitly reasoned and accepted: reposnapshots are not generated to debug trailing-whitespace parser errors in a small set of languages. Recorded so nobody "fixes" it later | settled 2026-08-15 | this session |
| 14 | **Whitespace *shape* inside a raw string literal is formatting, not data.** Two newlines versus one carries no meaning worth preserving | The principle that settles the multi-line-literal objection — and it marks where the principle stops: it covers ops that only touch whitespace, and does **not** reach `nfc`, `strip-zwsp`, or `trim-inner`, which change non-whitespace characters | settled 2026-08-15 | this session |
| 15 | **ZWJ U+200D and ZWNJ U+200C are not strippable at all** — not merely off by default, not offered as ops | They compose emoji sequences and separate Persian/Indic morphemes; deleting them is data corruption. The case that settles it is self-referential: any library that *processes* such text carries these characters in its fixtures, and this tool exists to carry such code intact. An opt-in switch would preserve the corruption path for whoever reads the op list without the reasoning | settled 2026-08-15 | format-ws .NOTES INVISIBLES |
| 16 | **`trim-inner` off by default** | The only default that reached *inside* a line to rewrite spacing that may be content (embedded SQL, fixed-width templates, aligned output, ASCII art). `format-ws` is lexically blind — no string masking, unlike rs-psstrip/rs-csstrip — so it cannot tell a literal from code | settled 2026-08-15 | format-ws .NOTES |
| 17 | **`max-blank-2` removed; `max-blank-1` is the default.** At most one blank line | Retaining two blank lines is not a configuration anyone wants here | settled 2026-08-15 | format-ws |
| 18 | **`eof-eot` removed** (U+0004 sentinel) | No consumer, and it was the one place the content stage deliberately emitted a C0 control into the stream — colliding with the codec's strip rule. Deleted rather than exempted | settled 2026-08-14 | format-ws |
| 19 | **`no-bom` retired**, subsumed by unanchored `strip-zwnbsp` | Real narrowing, not a rename: stripping *only* a leading BOM is no longer expressible | settled 2026-08-15 | format-ws |
| 20 | **`ensure-trailing-space`** — exactly one trailing space on non-empty lines, paired with `trim-trailing` | Reader tokenization: serialized rows should read `def func() \n`, not `def func()\n`, so the escape does not butt against code characters and blur the token boundary. **Non-empty lines only** — a space on a blank line would both spam `\n \n` and stop `max-blank-1` matching runs at all. Implemented as the zero-width insertion `(?m)(?<=\S)$` → `' '`: both exclusions fall out of the lookbehind for free, so it is additive and idempotent without testing for either case | settled 2026-08-15 | format-ws |
| 21 | **Lane split.** `format-ws` and `rs-indent` are code-lane; document ingestion gets its own markdown-safe whitespace processor and default chain | Keeps prose semantics (two-trailing-space breaks, fence integrity) out of the code-side processors entirely, instead of accruing caveats in them | settled 2026-08-15 | shard-format-notes §"Stage ownership" |
| 22 | **Ops mostly non-configurable** | Would make composition guarantees structural rather than incidental — `trim-doc` + `ensure-final-lf` produce exactly one final LF *because both always run*. Also makes `UnknownOp` unreachable, simplifying the receipt code rather than complicating it | **leaning** | this session |

## Byte semantics and stage ownership

| # | decision | why it is consequential | status | source |
|---|---|---|---|---|
| 26 | **`Attributes` does not own shard planning.** It is a reader-facing triage block — the row's `attributes:{…}` segment — and `rs.core.shards` owns its own measurement | The property making `SpanBytes` good as an attribute (deliberate invariance to emission settings, so it stays comparable across runs) is exactly what makes it wrong as a packing input, since packing predicts a shard **file's** size, which moves with those settings. Also inverts the dependency: shard membership is not an optional enrichment processor's business | settled 2026-08-15 | assemble-design §"Attributes does not own shard planning" |
| 27 | **The queued `ByteSpan → SpanBytes` alignment is retired, not renamed** | Checking the code showed it was a semantic downgrade dressed as a rename. LTS stamps `ByteSpan = GetByteCount($line)` — the full rendered row incl. meta, delimiters and newline (`RepoSnapshotLts.psm1:2319`) — and `Partition-Files` packs on that. Layer 3, not layer 2. Aligning the name would have dropped meta and delimiter bytes from every packing decision. The naming was inverted too: LTS's `ByteSpan` is a row *size* | settled 2026-08-15 | assemble-design; consolidation §B 6e rider |
| 28 | **6e (encoding/codec look-back) is unblocked.** It was parked pending serializer declarations; #16 is settled | Its assemble-facing item is live: `Encoding` rides into every entry bag and counts as a fully-present element in `Header.Elements`, though it is a run-level constant whose home is Header. Deliberately a decide-together set with golden-test exposure, not a drive-by. Still open within it: #17(a) source-encoding detection at ingest, #17(b) emission-encoding declaration, which has no carrier | **open** | consolidation §B 6e; assemble.psm1 docstring |

## Receipts

| # | decision | why it is consequential | status | source |
|---|---|---|---|---|
| 23 | **`Processing.Operations` reports what RAN, not what was requested** | A receipt claiming a fold that did not happen is worse than no receipt. Two ways it could lie: `nfc` declining on ill-formed UTF-16 (the empty catch swallowed it), and unrecognized op names echoed as applied. `Skipped` carries both, with reasons | settled 2026-08-15 | format-ws .NOTES |
| 24 | **The applied list is derived from execution**, not filtered against a declared roster of valid op names | Same reasoning as #6: a second list drifts. Op blocks append their own name as they run, so a new op participates automatically, and forgetting the append under-reports rather than over-claims — the safe direction, since over-claiming is the bug | settled 2026-08-15 | format-ws |
| 25 | A config mistake is **recorded, not thrown** | Never-fail-ingest covers content, not config, so throwing was defensible — but a typo should not cost the ingest. It must not be invisible either, hence `UnknownOp`. Revisit if #22 lands, which makes it unreachable | settled 2026-08-15 | format-ws |

## Notes

- **Two traps have now bitten twice each in this codebase**, and a third occurrence
  argues for `AGENTS.md` rather than a per-file comment:
  - *If-expression single-element unroll* — an if-expression enumerates its
    output, collapsing a one-element array to a scalar. Hit in
    `rs.core.assemble.psm1` (Phase 5) and again in `format-ws.ps1`'s receipt.
  - *Member access on an empty array writes to the error stream* — and colonel
    clears `$Error` before each processor call and attributes what it finds per
    item, so the common case hangs a spurious error on **every** item. Same
    mechanism as the `Set-StrictMode`-in-processor-bodies finding.
- **`run-all.ps1`'s error-stream check earns its keep.** It caught the empty-array
  defect while 764 asserts passed. A green battery is two signals, not one —
  count *and* clean stream.
- Where an entry is `open` or `leaning`, the live discussion lives in its source
  doc; this ledger records that the call is owed, not what it should be.
