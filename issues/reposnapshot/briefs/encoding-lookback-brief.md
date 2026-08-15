# Encoding look-back (consolidation 6e) — brief

**Status:** filed, unblocked, not started · **Filed:** 2026-08-15 ·
**Track:** V3 e2e sprint — the one assemble-facing item the emission work touches.
Sources: consolidation plan §B 6e · payload-manifest-ledger #17 ·
`rs.core.assemble.psm1` docstring ("NOT excluded, under review") ·
assemble-design §Payload doctrine.

## Why it was parked, and why it isn't any more

6e was filed 2026-08-09 as a consequence of siting the encoding and codec
declarations at the serializer. It was deliberately left as a **decide-together
set**: *"no code changed yet — every item below is a live behavior with a test
behind it, and they want deciding together, not piecemeal."*

It was waiting on serializer decisions that have now landed — the codec is
settled (ledger #16, `shard-format-notes.md` §"Content codec — SPEC"). The rider
about `Partition-Files` probing `ByteSpan` has separately been **retired** rather
than actioned (decisions-ledger #27). What remains is the encoding half.

## The set

**1. `Encoding` rides into every entry bag.** `file-read` stamps it; assemble's
`$alwaysExcluded` is `@('AbsolutePath', 'SizeBytes', '_ChainHalt')` and does not
filter it ([rs.core.assemble.psm1:151](../../../utils/reposnapshot/reposnapshot-v3/rs.core.assemble.psm1)).
So a run-level constant repeats once per entry and is counted as a
**fully-present element** in `Header.Elements` — a 100% coverage figure for
something that carries no per-entry information.

**2. `file-read`'s `Encoding` is an assertion, not a detection.** It decodes UTF-8
unconditionally — no BOM sniff, no UTF-16 branch. So the field asserts a policy
while looking like a measurement, and a reader handed mojibake cannot tell whether
the source was odd or the pipeline was wrong.

**3. UTF-16 sources are misrouted, correctly, for the wrong reason.** They are
NUL-dense, so the binary guard routes them to Diagnostics as
`BinaryOrNulContent`. They are caught — by accident, under a misleading reason.
Worth weighting: this is a **PowerShell** project, and PowerShell ISE historically
saved `.ps1` as UTF-16 LE, so this is not a hypothetical corpus.

**4. Emission encoding (#17b) has no carrier at all.** Ledger #17 splits the
question in two — (a) *source* encoding per entry, what the ingested bytes decoded
as, an ingest-stage fact; (b) *emission* encoding of the payload artifact, a
serializer declaration. Nothing declares (b) anywhere today.

## Why they must be decided together

Item 2 determines item 1, in opposite directions:

- **If `Encoding` stays an assertion**, it is a run-level constant and belongs in
  Header — assemble's exclusion list grows and the field leaves entry bags.
- **If detection lands**, `Encoding` becomes a genuine per-entry measurement and
  **belongs exactly where it is**. Moving it first would be work to undo.

That is the whole reason 6e was filed as a set rather than four tickets.

## Recommendation

**Implement bounded detection, and let the two declarations settle into different
homes.** Concretely:

- `file-read` gains a **BOM sniff** (UTF-8, UTF-16 LE/BE, UTF-32 LE/BE) plus a
  cheap BOM-less UTF-16 heuristic — alternating NUL bytes in a bounded prefix. Not
  charset detection; no dependency, no statistical guessing beyond that.
- `Encoding` thereby becomes a real per-entry fact and **stays on the entry**.
  Item 1 resolves by making the field honest rather than by relocating it.
- Item 3 resolves as a side effect: UTF-16 files decode instead of being
  misclassified as binary. Where a file still fails, the diagnostic reason should
  distinguish "looks like UTF-16" from "binary".
- **Header carries the *emission* encoding** (#17b) — a genuinely run-level fact,
  and the natural neighbour of the Compaction notice in the tree file, since both
  are statements about how to read the artifact. Expect UTF-8 without BOM, which is
  what LTS emits (`[System.Text.UTF8Encoding]::new($false)`); the work is declaring
  it, not choosing it.

This gives ledger #17's two declarations **different homes because they are
different facts**, which is the shape the ledger already implies.

*Cheaper alternative, if detection is judged out of scope:* rename the field to
admit what it is (`DecodePolicy` / `DecodedAs`), move it to Header, and leave the
UTF-16 misrouting documented rather than fixed. Honest, no behavior change, and it
forecloses nothing — detection can arrive later and move the field back.

## Risk — read before touching code

- **Golden-test exposure.** `assemble.tests.ps1` is 53 asserts *including the
  golden validation* against a live LTS monolith. The entry-bag exclusion list is a
  macro-convention with that test behind it. The consolidation plan's own words:
  *"hence not a drive-by."*
- **`file-read` has no dedicated test suite.** The 14-suite battery has no
  `file-read.tests.ps1`; it is covered only incidentally through
  `pipeline.smoke.tests.ps1` and `mutator-chain.tests.ps1`. **Changing decode
  behavior without first standing up a suite for it would be changing the least
  covered file in the chain.** Treat that suite as part of the work, not a
  follow-up.
- Fixtures need real byte sequences — UTF-16 LE/BE with and without BOM, UTF-8
  with BOM, a lone-surrogate case (already exercised via `nfc`), and a genuinely
  binary file — written as bytes, not as strings in a `.ps1`.

## Exit gate

- A UTF-16 LE source file with a BOM ingests and its content is correct, rather
  than being routed to Diagnostics as `BinaryOrNulContent`.
- `Encoding` reflects what was actually detected, per entry, and differs across a
  mixed fixture set.
- The payload declares its emission encoding somewhere a reader meets before the
  content.
- New `file-read` suite green; `assemble.tests.ps1` green **including the golden
  validation**, with any intended delta asserted as a documented known-delta rather
  than silently accepted.
- Full battery green **and error stream clean**.

## Non-goals

- Charset detection beyond BOM plus the bounded UTF-16 heuristic. No statistical
  guessing, no dependency — the zero-dependency stance is load-bearing, since a
  snapshot's content must not vary with the producing machine.
- Transcoding on emission. The artifact is UTF-8; sources that decode from
  something else are still emitted as UTF-8.
- Re-opening the codec (#16), which is settled.

## Open calls

- **Detect or rename** — the fork above. Everything else follows from it.
- **Where the emission declaration goes**: tree file beside Compaction, shard
  header row, or both.
- **Forward pointer, speculative:** under the per-shard schema idea
  (`schema-derivation-brief.md`), an element holding a single distinct value across
  a shard could be declared once in that shard's header instead of repeated per
  row. `Encoding` is the obvious first candidate. Noted as a connection, not a
  dependency — neither brief should wait on the other.
