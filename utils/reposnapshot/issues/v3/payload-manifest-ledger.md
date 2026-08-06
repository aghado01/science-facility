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

## Notes

- Seeded 2026-08-04 from the design docs; **not exhaustive**. The point is that
  new settings of consequence get filed here as they are decided, rather than
  scattered across design docs and rediscovered later.
- The manifest itself is a writer-phase product. Nothing here is emitted until
  writers exist; several entries are already computed and simply not yet
  rendered (#1–#5).
- Where an entry is `open`, the open decision lives in its source doc — this
  ledger tracks that the declaration is *owed*, not what its value should be.
