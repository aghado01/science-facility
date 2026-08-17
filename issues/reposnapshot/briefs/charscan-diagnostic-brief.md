# Character-scan diagnostic step — brief

**Status:** filed, not started · **Filed:** 2026-08-15 · **Priority:** side quest —
does not block the V3 e2e sprint (`assemble → shards → serialize`). The decision
behind it is already captured (decisions-ledger #11 / #11b), so deferring the
code loses nothing.

## Why it exists

Closing the bidi question produced a gap rather than a task. Bidi controls are
**not** strippable — they are load-bearing content in i18n resources and mixed-RTL
literals, the same category as ZWJ/ZWNJ — but their presence in a source file is
genuinely unusual and worth surfacing. There is currently nowhere for an
observation of that shape to go: "notable, but nothing the content stage should
act on."

That is a diagnostic, and the pipeline has a position class for it already.

## Position and mechanism

**Position class: enrich-only, read-only tail — the `rs-content_meta` class.** Runs
after ALL content mutators. Position is a **profile invariant** (admiral's); the
processor stays position-ignorant, exactly as rs-content_meta does.

*Why after mutation, specifically:* it must report on the content that actually
ships. A scan running earlier would report characters later removed and miss
characters later introduced, so its findings would describe a document nobody
receives.

**Mechanism — no new machinery.** The processor attaches an element to the bag;
`Invoke-Assemble` declares it in `Header.Elements` without knowing what it is
(open element model, zero per-element branches); the writer decides emission
("compute-by-default, emission is a writer knob" — rs-content_meta' split). That is
how a diagnostic stays out of the payload without the processor knowing sidecars
exist. Nothing in assemble, colonel, or the manifest changes.

## Scope — narrow, and grown by accretion

**Bidi controls only, to start:** U+202A–U+202E (LRE/RLE/PDF/LRO/RLO) and
U+2066–U+2069 (LRI/RLI/FSI/PDI).

Deliberately not a general content-anomaly taxonomy. Inventing the category list
before there is evidence about what is worth reporting is how the retired preview
processor went wrong — and the standing posture for capabilities of this kind is
*discovered by use, not specified up front* (assemble-design §"Structural survey
elements"). New detections join when something real asks for them.

## Contract

- **Item contract:** enrich-only. Reads `Content`, attaches its element, mutates
  nothing. Follow rs-content_meta' copy-on-enrich via `processors/bag-helpers.ps1`
  rather than re-deriving the clone.
- **No-Content contract:** a bag carrying no content passes through unenriched, so
  the step is safely appendable to arbitrary profiles including thread envelopes.
- **IssPreset floor / IssModules:** state them in the standard self-doc block.
  Expect a low floor — this is a string scan with no cmdlet dependencies.

**Attach the element ONLY when something is found.** This is the one design point
worth getting right up front, and it follows from how assemble counts. `Elements`
records per-element *presence* counts across entries. An element attached
unconditionally would report 100% coverage of a thing that is empty in almost
every entry — noise. Attached only on a finding, the same count becomes directly
useful: *how many entries had findings*. Absence is information, the same
property that makes `format-ws`'s `Skipped` worth reading.

## Exit gate

- Suite under `processors/tests/` following the house harness pattern, with the
  `SUITE ABORTED` catch retained.
- Verified through **colonel dispatch in a worker runspace**, not only dot-invoked
  — the fleet's standing requirement.
- The element flows end-to-end: present on entries that have findings, absent on
  those that do not, and `Header.Elements` reports the finding count rather than
  the entry count.
- Full battery green **and error stream clean**. Both signals — `run-all.ps1`'s
  error-stream check caught a defect this session that 764 passing asserts did
  not.

## Non-goals

- Stripping or altering anything. This step never mutates content.
- Sidecar form, naming, or routing — writer-phase, and open (payload doctrine).
- The broad anomaly taxonomy (mixed indentation, unpaired surrogates, suspicious
  invisibles). Candidates, not scope.
- Anything that overlaps `rs-content_meta`' per-entry metrics.

## Open calls

- **Processor name.** `rs-charscan.ps1` says what it does and leaves room for
  siblings; `rs-diagnostics.ps1` claims the whole space for what is initially a
  bidi scanner. Recommend the former, on the same one-concern-per-op logic that
  split `strip-zwsp` into three.
- **Element name and shape.** Counts alone, or counts plus locations? Locations
  (line/column) cost a scan position to track and are only worth it if something
  consumes them — nothing does yet.
- **Whether findings should ever reach the payload**, or are strictly sidecar.
  Ties into the unresolved sidecar form; safe default is compute-and-withhold.
