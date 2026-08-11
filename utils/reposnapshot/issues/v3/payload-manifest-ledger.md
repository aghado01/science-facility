# Payload manifest ledger

Running registry of **declarations of consequence** — settings and postures that
must surface in the eventual payload manifest so a reader knows what artifact it
is holding.

Standing project posture: **keep receipts.** Entries here are filed, not argued —
rationale lives in the linked design docs. Append as things arise; this is a
collection point, not a decision forum.

Status vocabulary: `live` (emitted today) · `settled` (decided, awaiting the
writer phase) · `open` (needs a call) · `forward` (belongs to shelved work).

## Registry

| # | declaration | why it is consequential | status | source |
|---|---|---|---|---|
| 1 | `Header.Elements` — observed per-element presence counts | tells a reader what element families the payload actually carries, without assemble knowing any of them | live | assemble-design §"Open element model" |
| 2 | `EntryRouting` — `LeanPayload` \| `KeepContentless` | changes which entries exist at all; a reader must not read absence as "file not present" | live (param) | assemble-design; payload doctrine |
| 3 | `Adapter` — track adapter in force (`Code`) | which track's shape the entries follow | live (param) | assemble-design §"Track adapters" |
| 4 | RunContext — `Root`, `GeneratorVersion` | provenance of the run | live | assemble-design |
| 5 | `Processing` trail — processor + ops per entry, chain-ordered | the receipt for what was done to the content a reader is looking at; also the per-entry evidence behind #6 | live (per-entry) | consolidation 6d; processors' `Processing` element |
| 6 | **Channels carried** — core logic / rendering / documentation / runtime directive / tooling directive / attestation | a source file overlays several channels and filtering selects among them; a reader must know which ones this payload contains before concluding anything from an absence. Needs a header-level summary; #5 is the per-entry evidence | open | comment-ontology §"Beyond comments — excisable code regions" |
| 7 | **Survey fidelity** — `ast` \| `regex` per language | distinguishes "no edge exists" from "could not see edges" | forward | assemble-design §"Structural survey elements"; structural-survey-brief |
| 8 | Byte-layer identification for any emitted offsets | SizeBytes / SpanBytes / rendered row length are three different things; offsets are useless without their unit. Char vs UTF-8 must be explicit | settled (doctrine) | assemble-design §"Payload doctrine"; span anchors |
| 9 | Sidecars present and where — diagnostics, config crosswalk, comment sidecar | a reader needs to know what was moved out of the payload rather than dropped | forward | payload doctrine; content-class dispositions; comment-ontology §"Stripping need not be lossy" |
| 10 | Ignore/selection regime — mode + effective patterns | what the run excluded; absence from the payload is otherwise unexplained | open | ignore-selection-inversion.md |
| 11 | Effective config — `{ Name; Value; Source = Caller \| TargetDefault \| WrapperPolicy }` | records what the run *actually ran with*, including "Auto — computed at dispatch", which a materialized value could never express | deferred | consolidation §E "Effective-config resolver"; ConfigEcho |
| 12 | Header `flags` block — retire vs keep | derived redundancy over ConfigEcho, or reader quick-orientation | open | assemble-design open decision 5 |
| 13 | `Header.Root` emission posture — absolute vs path doctrine | leaking system paths into web-bound payloads | open | assemble-design open decision 6 |
| 14 | `git_history` — optional RunContext enrichment | provenance; unexercised in practice | open | assemble-design open decision 7 |
| 15 | Content-class routing in force — which classes ingested vs pointer vs own track | config-as-pointer and docs-as-own-track mean a reader must know the run's disposition to interpret coverage | forward | assemble-design §"Content-class dispositions" |
| 16 | **Content codec in force** — the escape regime the serializer applies to the emitted content span: the **mechanism and alphabet** (prefix-sigil vs 1:1 codepoint substitution, and which substitute table), which characters are escaped, and the **EOL posture** (preserve CRLF/CR/LF distinctly vs normalize to LF). **Carrier settled (user, 2026-08-09): the substitution dictionary ships in the artifact — tree file, or a shard header / row-zero block** — the same place the column schema is already declared, so this is existing doctrine applied to one more thing, not new machinery. **It is a cipher key, not a decoder spec**: the manifest is never a decoder, payloads are read as-is without tooling, and the dictionary exists so a reading model has absorbed the sigil↔character correspondence *before* meeting one. Hence it must precede the content it explains, and read as a short legible correspondence rather than a grammar. **Concrete form (user, 2026-08-09): a `Compaction` block in the tree file** — the exclusive entrypoint, read first, so precedence is structural rather than a rule anyone must remember. Lists the substitutions **actually made** (a receipt, not a capability catalog — an absent `\r` entry tells a reader no CR survived), each naming the target character *and* its code point, since `{newline}` would blur the LF/CR/CRLF distinction the preserve stance exists to keep. Implementation site: `rs.core.template.ps1`, a new optional section + model-builder field | the virtual-DB contract hands a reader raw bytes at `row_content_begin..row_content_end` and expects source text back. The length prefix guarantees the *frame*; nothing declares the *decode*. **The custom container authors its own escape regime** — no `ConvertTo-Json` in that path (see Notes) — so unlike a JSON payload there is no external spec a reader can fall back on. Undeclared, an encoded newline is indistinguishable from a literal backslash-n and no span round-trips to source. If the regime ever normalizes EOLs, that is lossy and the declaration is what stops a reader rebuilding files with the wrong terminators | open | shard-format-notes §"Escape regime — codec spec" |
| 17 | **Character encoding, two declarations** — (a) *source* encoding per entry, what the ingested bytes decoded as; (b) *emission* encoding of the payload artifact | distinct from #8, which fixes the offsets' *unit*; these say what the bytes decode as at each end. Different owners: (a) is ingest-stage fact, (b) is a serializer declaration. Today `file-read.ps1` stamps `Encoding = 'UTF-8'` as a **constant** — no BOM sniff, no UTF-16 detection — so (a) is an assertion, not a measurement, and a reader handed mojibake cannot attribute it to the source vs the pipeline. (b) has no carrier at all yet | open | file-read.ps1; assemble-design §"Payload doctrine" |

## Notes

- Seeded 2026-08-04 from the design docs; **not exhaustive**. The point is that
  new settings of consequence get filed here as they are decided, rather than
  scattered across design docs and rediscovered later.
- The manifest itself is a writer-phase product. Nothing here is emitted until
  writers exist; several entries are already computed and simply not yet
  rendered (#1–#5).
- Where an entry is `open`, the open decision lives in its source doc — this
  ledger tracks that the declaration is *owed*, not what its value should be.
- **No shared escaping between the two writers** (user, 2026-08-09). The custom
  container's codec (#16) is hand-authored by its serializer; the JSONL writer
  gets escaping free from its own serialization. Hijacking `ConvertTo-Json` to
  escape the custom container — LTS's approach, and a live suggestion in earlier
  discussion — is **declined for this pass**: it couples two writers that have no
  reason to share a code path, and drags JSON's escape regime into a format whose
  whole point is not paying it. Consequence for #16: the codec has no external
  spec behind it, so declaring it is the only thing that makes a span decodable.
