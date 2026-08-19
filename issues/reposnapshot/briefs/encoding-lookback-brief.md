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
than actioned (decisions ledger #27). What remains is the encoding half.

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

**3. UTF-16 sources land in Diagnostics under a misleading reason.** They are
NUL-dense, so the binary guard halts them as `BinaryOrNulContent`. Note carefully
what is and is not wrong here — see the pipeline context below. Both filters are
behaving correctly; only the *reason* misdescribes a text file in another
encoding. `file-read.ps1`'s own docstring already admits this. Worth weighting:
this is a **PowerShell** project and PS ISE historically saved `.ps1` as UTF-16
LE, so the corpus is not hypothetical — though modern PowerShell, VS Code and
`Set-Content` all default to UTF-8, which makes it a legacy-corpus concern rather
than a live one.

## Pipeline context — the read budget, and why it constrains this

**The pipeline reads each file exactly once, and answers every question it can
from metadata first:**

| stage | what it does | I/O |
|---|---|---|
| crawler | walk, stamp identity + `SizeBytes` + `LastWriteUtc` from one `FileInfo` | no content read |
| ignore | size ceiling + **hard extension blacklist** (`.exe .dll .pdb .so .dylib .wasm` …, caller additions additive) | **none** — pure metadata filter |
| file-read | `[IO.File]::ReadAllBytes` → NUL guard on those bytes → decode | the single read |

Three consequences that bear directly on this work:

- **Binary exclusion is primarily extension-based and costs nothing.** The NUL
  guard is an *opportunistic fallback* for what slips through — a mislabelled or
  extensionless blob — inspecting bytes already in memory
  (`rs.core.ingest.psm1:19-21`). It is not the primary mechanism and should not be
  redesigned as though it were.
- **A BOM sniff is free on this budget.** The bytes are already in hand; reading
  `$bytes[0..3]` adds no I/O. Nothing here argues against detection on cost
  grounds.
- **But detection must run BEFORE the NUL guard**, because UTF-16 content is
  legitimately NUL-dense. That reorders the most load-bearing lines in the file
  and changes what the guard means: "contains NUL" is evidence of binary only for
  a byte stream believed to be 8-bit text. Once UTF-16 is admitted, NUL density is
  expected rather than disqualifying. **This is the real risk in the work — not
  the decoding.**

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

## Three options, cheapest first

**(a) Rename only — no detection.** `Encoding` becomes `DecodePolicy` (or
`DecodedAs`), admitting it states what the reader *did*, and moves to Header as
the run-level constant it is. No behavior change, the NUL guard is untouched, and
the UTF-16 gap is documented rather than closed. Forecloses nothing: detection can
arrive later and move the field back.

**(b) BOM sniff only — recommended.** Inspect the leading bytes; if a BOM is
present, trust it, decode accordingly, and **skip the NUL guard when the BOM says
UTF-16/UTF-32**. No heuristic anywhere. A BOM is unambiguous evidence, so the
guard's semantics change only in the narrow case where something authoritative
said "this is not 8-bit text" — everything else keeps today's behavior exactly.
`Encoding` becomes a real measurement for BOM-bearing files and stays on the
entry.

**(c) BOM sniff plus a BOM-less UTF-16 heuristic** (alternating NULs in a bounded
prefix). Closes the remaining gap, and buys it by making the binary guard
conditional on a *guess*. That inverts the current relationship — a fallback guard
would start deferring to a heuristic — in the file with no dedicated test suite.
**Not recommended without that suite standing first.**

The earlier draft of this brief recommended (c) without weighing the guard
reordering; (b) is the better trade. Note (b) leaves BOM-less UTF-16 caught by the
NUL guard exactly as today, which is a real residual gap and an acceptable one —
it is the case with no evidence to act on.

Independent of the fork, and cheap in all three:

- **Header carries the *emission* encoding** (#17b) — genuinely run-level, and the
  natural neighbour of the Compaction notice in the tree file, since both state how
  to read the artifact. Expect UTF-8 without BOM, which is what LTS emits
  (`[System.Text.UTF8Encoding]::new($false)`); the work is declaring it, not
  choosing it.

Under (b) or (c), ledger #17's two declarations end up in **different homes
because they are different facts** — per-entry source encoding measured at ingest,
run-level emission encoding declared by the serializer — which is the shape #17
already implies. Under (a) both are run-level and both live in Header.

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

*(Under (b) or (c); option (a)'s gate is just "the field says what it means and
the battery is green".)*

- A UTF-16 LE source file **with a BOM** ingests and its content is correct,
  rather than being routed to Diagnostics as `BinaryOrNulContent`.
- **A genuinely binary file still halts.** This is the assertion that matters —
  the guard was reordered, so prove it did not weaken. An `.exe`-shaped fixture
  with no BOM must still produce `BinaryOrNulContent`.
- **A BOM-less UTF-16 file still halts under (b)**, asserted deliberately rather
  than left ambiguous, so the residual gap is a recorded choice and not a
  discovery for whoever reads it later.
- `Encoding` reflects what was actually detected, per entry, and differs across a
  mixed fixture set.
- The payload declares its emission encoding somewhere a reader meets before the
  content.
- New `file-read` suite green; `assemble.tests.ps1` green **including the golden
  validation**, with any intended delta asserted as a documented known-delta rather
  than silently accepted.
- Full battery green **and error stream clean**.

## Non-goals

- Charset detection. No statistical guessing, no dependency — the zero-dependency
  stance is load-bearing, since a snapshot's content must not vary with the
  producing machine.
- **Redesigning binary exclusion.** That is the extension blacklist's job, it
  costs no I/O, and it works. The NUL guard is a fallback and stays one.
- Transcoding on emission. The artifact is UTF-8; sources that decode from
  something else are still emitted as UTF-8.
- Re-opening the codec (#16), which is settled.

## Open calls

- **Which of (a) / (b) / (c)** — the fork above. Everything else follows from it,
  including whether `Encoding` moves to Header or stays on the entry.
- **Where the emission declaration goes**: tree file beside Compaction, shard
  header row, or both.
- **Forward pointer, speculative:** under the per-shard header-row idea
  (`shard-container-brief.md` §crux), an element holding a single distinct value across
  a shard could be declared once in that shard's header instead of repeated per
  row. `Encoding` is the obvious first candidate. Noted as a connection, not a
  dependency — neither brief should wait on the other.
