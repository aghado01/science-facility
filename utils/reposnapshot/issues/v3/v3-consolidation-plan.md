# v3 consolidation plan — shore up before breaking ground

**Status:** EXECUTED through Phase 5 (2026-07-29) — inventory items carry
✓ markers; remaining open: **6d** (tp-era contract harmonization —
adjudicated 2026-07-29, implementation pending), **item 6** (crawler
diagnostics split, cosmetic), and the horizon (writers → admiral →
thread track) · **Filed:** 2026-07-28

**Doctrine (user):** shore up the gaps, bugs, and follow-ups in existing
reposnapshot v3 code *before* breaking new ground. The next-stage work
(rs.core.assemble) waits until the pipeline it sits on is sound.

This doc is the canonical sequenced plan; design detail lives in the
cross-referenced docs. Update phase status here as work lands.

## Doc-alignment audit (2026-07-28 — applied)

- `ignore-selection-inversion.md`: dangling "v1 … below" reference fixed (v1
  was replaced in place; its record lives in the work log).
- Transfer-audit inventory (Ignore/selection row): now points at the completed
  Design v2 + reconciliation.
- `TODO.md`: antisemantics item marked design-complete with pointer;
  monolith-optional item marked subsumed by IR distillation; MVP-gaps item
  points here.
- Admiral brief open question 2 (RelativePath enrichment home) marked resolved
  → crawler output contract (ItemDescriptor).
- Remaining consistent set: admiral brief (mission, thinness, code/config,
  through-line, wrapper mechanism, ingest reframe, residues, control-flow
  opens) · transfer audit (inventory + session work log) · assemble seed
  (contracts, decomposition, golden validation) · inversion doc (lineage,
  Design v2, reconciliation, cautions).

## Open-items inventory

### A. Bugs / live breaks (fix first) — ✓ ALL FIXED (Phases 1 + 3)

1. **Ingest→processor Items seam** — `Invoke-Ingest` passes AbsolutePath
   strings; processors expect descriptor objects; every chained item
   `_ChainHalt`s. (transfer-audit work log; assemble-design ItemDescriptor.)
2. **Crawler missing identity/stat fields** — no `RelativePath`, no
   `LastWriteUtc` on file entries; both free at walk time. (ItemDescriptor.)
3. **Ignore stamps RelativePath** — enrichment inside a filter stage; hidden
   dependency. De-stamp once crawler stamps. (admiral residue #1.)
4. **Colonel processor validation rejects interior helpers** — regex at
   `rs.core.colonel.v2.psm1` ReadProcessorScript kills tp-perplexity
   (`_MaskByRegex`). AST fix: reject only a single wrapping
   FunctionDefinitionAst / missing top-level param block.

### B. Refactors — design settled, code pending

5. ✓ DONE (Phase 2) — **Ignore/selection Design v2→v3** (`ignore-selection-inversion.md`): mode-aware
   rim over neutral core; regime-stamped `CompiledState`; override rescue;
   prune policy; config surface with binding-aware coherence validation.
   *Blocked only by naming adjudication (user):* `-Mode` values;
   `OverridePatterns` / `SelectionPatterns`; `ExecutiveOverrides` shim vs
   clean break.
6. **Crawler diagnostics split** (crawler's own TODO) — separate diagnostics
   feed from graph result. Optional rider on Phase 1; cosmetic.
6b. ✓ DONE — **Legacy `tests/colonel.tests.ps1` was stale** — targets the retired
   `rs.core.colonel.psm1` (v1) path; refresh against v2 or retire (small).
   Validation coverage now lives in `tests/colonel-validation.tests.ps1`.
6d. **tp-era item-contract harmonization** (found 2026-07-29 during Phase 5):
   `format-ws.ps1` and `rs-psstrip.ps1` unpack `$Item.Text` and REPLACE the
   bag with an Id/Path/Text envelope — the tp-era contract, incompatible
   with the descriptor contract (`Content`, open-bag copy-on-enrich). In a
   code-track chain they would destroy identity fields. Harmonize: accept
   Content|Text, enrich-in-place instead of envelope replacement (or an
   adapter shim); decide the envelope's fate for the thread track. Blocks
   content-transform parity (strip/ws) in code-track chains and the
   comment-ontology "LTS dispatches to processors" end state.
   **Adjudicated 2026-07-29 (user): bag-native copy-on-mutate, no shim.**
   The defect is the envelope swap, never the mutation — mutating Content
   is these processors' job (position class: content mutator). Harmonized
   shape: clone the incoming bag, replace Content with the transformed
   text, pass every other property through — the mutator sibling of
   file-read's copy-on-enrich. Input dual-key (Content preferred, Text
   fallback — tp-perplexity's existing pattern, keeps intra-thread-track
   chains working). Envelope Id/Path fields are redundant with descriptor
   identity; useful envelope cargo (rs-psstrip's Operations record)
   becomes an attached element — the open element model absorbs it and
   assemble declares it without knowing it. Transforms unchanged
   byte-for-byte; the edit is the rim of each script, and the suites
   (format 29 / rs-psstrip 79) pin transform semantics. Rationale (user):
   chain members hand off like every other member; the chain's product is
   a correctly mutated, preprocessed input to the assemble step. The
   tp-era envelope's fate NARROWS out of processor scope: it is now a
   thread-track rim question (wrap exchanges into Content-keyed bags at
   ingestion — envelope disappears — vs some envelope form surviving as a
   wire/arrangement shape at emission); admiral/thread-milestone decision.
6c. ✓ DONE — **rs-psstrip FrontMatter kind promotion** (design clarified by user
   2026-07-28, comment-ontology item 1): replace the `^#requires\b`
   population-exclusion text guard in the AST route with classification to a
   named `FrontMatter` kind — lexical objects filtered by kind name; text
   pattern recognition belongs to the regex fallback route only. Includes
   explicit run-splitting semantics + clean-parse preservation asserts in
   rs-psstrip.tests.ps1 (68/68 baseline).
   **Scope sharpened after reading the lineage source** (psdig
   ast-primitives — extraction recorded in comment-ontology item 1): restore
   the *partition at the parse boundary* — text match exactly once at the
   promotion site producing Derived kind objects with spliced
   `$ast.ScriptRequirements` metadata; classification consumes the Native
   stream with zero text predicates. Implemented as an interior helper
   (permitted since the Phase 3 colonel AST fix — the sequence unblocked its
   own next item); centralization **adjudicated 2026-07-28: self-contained**
   (no rs.core ast-primitives module — PS prominence in RS processing is
   contingent; script-surface generality not needed now; see the
   comment-ontology language-expansion doctrine: thoughtful-regex processors
   are the default for new languages, native AST on demand). 6c has zero
   open decisions.
6e. **Encoding/codec look-back** (user, 2026-08-09) — consequence of siting
   both declarations at the serializer stage (assemble-design §Payload
   doctrine; ledger #16/#17). Docs, docstrings and planning updated in the
   same pass; **no code changed yet** — every item below is a live behavior
   with a test behind it, and they want deciding together, not piecemeal:
   - `Encoding` rides into every entry bag. file-read stamps it, assemble's
     `$alwaysExcluded` does not filter it, so a run-level constant repeats
     once per entry and counts as a fully-present element in
     `Header.Elements`. Header is its home while it stays constant; per-entry
     is right only if detection lands. Fixing it edits the macro-convention
     exclusion list — golden-test-bearing, hence not a drive-by.
   - **file-read's `Encoding` is an assertion, not a detection** — decodes
     UTF-8 unconditionally, no BOM sniff, no UTF-16 branch. Either detect for
     real or rename the field to admit it is a decode policy. Note the
     incidental behavior: UTF-16 sources are dense in NUL bytes, so the
     binary guard routes them to Diagnostics as `BinaryOrNulContent` — they
     are caught, but by accident and under a misleading reason.
   - **rs-attributes measures in canonical UTF-8 by convention** — now stated
     in its docstring rather than implied. Content in memory is UTF-16; the
     byte span only exists once an encoding is chosen, and the processor
     chooses one upstream of the stage that owns the choice. Keeping UTF-8 is
     deliberate (attributes must be invariant to writer knobs to stay
     comparable across runs), but it needed saying out loud.
   - Rider, already queued: `Partition-Files` probes `ByteSpan`; align to
     `SpanBytes` when writers land (assemble-design §Payload doctrine).

### C. Capability gaps (LTS parity, pre-assemble) — ✓ ALL DONE (Phases 1 + 4)

7. **rs-attributes.ps1** — tail-step processor: entry metrics + binary flag;
   compute-by-default, emission is a writer knob. (transfer-audit disposition.)
8. **Pipeline smoke test / harness-as-admiral** — end-to-end
   crawl→ignore→ingest→file-read over this repo, exercising the
   build-against-absent-admiral contracts.

### D. New ground (after consolidation)

9. ✓ DONE (2026-07-29, golden green) — **rs.core.assemble** (name adopted) per design seed: DispatchOutput +
   RunContext + AssemblyPolicy → IR; code-track adapter; golden data-to-data
   validation vs a fresh LTS monolith JSON.

### E. Explicitly deferred

~~Preview processor~~ (RETIRED as a concept 2026-07-28 — successor named
2026-08-04: **structural survey elements**, assemble-design §"Structural
survey elements" for design + feasibility boundary + span-anchor decision,
implementation brief in `structural-survey-brief.md`. Not truncated content
but extracted shape — signatures / declarations as a cheap high-level index so
a reading agent can spend context only on spans that survive the survey.
Enrich-only processor + open element model, no new machinery; PS extraction
prototyped in `tools/rs.dev.signatures.psm1`, and the port is a WRAPPER on it
via colonel's existing IssModules import, never a copy. First preview-adjacent
capability to arrive organically — discovered by use, not specified up front)
· Filter-Content retire decision · tree model
home · all writers/serializers · admiral implementation (brief keeps
accruing) · thread adapter + corpus first milestone · mutation-ownership
doctrine beyond copy-on-enrich (waits for admiral state design) ·
subaddressing.

**Escape regime — spec written ahead of the serializer** (user, 2026-08-09;
`shard-format-notes.md` §"Escape regime — codec spec"). Written so the writer
work inherits the requirements rather than rediscovering them.

Scope is set by the length prefix: framing never depends on encoding, so the
only HARD requirement is the one-record-per-line invariant — LF, CR, VT, FF,
NEL, LS, PS. Remaining C0 + DEL are soft (reader hygiene, total inverse).
Coverage target is `ConvertTo-Json`'s set plus DEL, whose measured behavior is
recorded in the doc as a reference point. Standing requirements: CR encodes
distinctly from LF (or CRLF stops being recoverable); the codec stays total and
does not lean on the upstream NUL guard (`format-ws`'s `eof-eot` op deliberately
puts U+0004 *into* content).

**Sigil — narrowed to two coherent designs, decision open.** The user asked
whether an invisible code point could replace `\`, and corrected a first-pass
error worth recording: `strip-zwsp` deleting the invisibles **reserves** them for
the serializer rather than disqualifying them — the op runs upstream of
serialization, so collision-freedom is handed over for free, the same structural
move as ` | ` being safe because `|` is filesystem-invalid. Rider: the codec
should not *depend* on that (format-ws is opt-in, op list subsettable) — it
self-escapes by doubling regardless, and the reservation's value is that the
escape never fires.

**Resolved on token economy: `\` backslash prefix** (user raised token cost,
2026-08-09; supersedes an interim Control Pictures recommendation). The governing
insight: **rarity and token-cheapness are the same axis inverted** — a code point
rare enough to be safe is rare enough to be out-of-vocabulary, so it byte-falls-
back at ~1 token per UTF-8 byte. Exotic markers of every kind (Control Pictures,
ligatures, small-punctuation blocks, zero-widths) land at 3-4 bytes ≈ 3-4 tokens
against a raw newline's ~1. On a 2 MB / ~50k-line shard that is **+100k tokens**.
`\n` is near-certainly a single merged BPE token — the property of being the most
common escape sequence in existence is exactly what buys that, and it is
unavailable to anything chosen for obscurity.

The objection to `\` was never token cost but the self-escape obligation, so it
was **measured** on the corpus most hostile to it (PowerShell — Windows paths and
regex): **+3.4%** (16123 newlines, 545 backslashes), and +3.3% on markdown. The
"unbounded worst case" framing was true in theory, negligible in practice. Same
scan disqualified alternatives: backtick 64.4% in markdown (and PS's own escape
char), `@` 7.2% in PS. Tilde is rare (0% PS / 1.4% md) but a rare ASCII prefix
makes `~n` an uncommon byte pair — likely 2 tokens where `\n` is 1, and newline
escapes outnumber self-escapes ~30:1, so per-newline cost dominates.

Kept on file rather than discarded: Control Pictures for human-inspection or
debugging payloads; **RS U+001E** as the one genuinely cheaper option (1 byte, C0
delimiter by design) — rejected on transport risk, since raw C0 bytes trip the
binary-classification heuristics external tools apply to `.txt`, which our
NUL-only guard would not catch.

**Two objections retired by the user (2026-08-09), narrowing this to one number.**
Renderer behavior is not a concern (IDE display is not the consumption path),
which drops the ZWSP-break-opportunity and SHY-hyphen points; and
misinterpretation is handled by shipping the **substitution dictionary in the
artifact** — tree file or shard header/row-zero — which is where the column schema
already lives, so it is existing doctrine reused rather than new machinery
(carrier now recorded on ledger #16). Declaration fixes correctness but not price:
the dictionary is paid once per shard, the substitute once per line.

**Escape-layer collision (user, 2026-08-09) — the strongest argument against `\`,
and it is on the primary axis.** `\` is the escape character in exactly the
languages queued for ingestion (C#, JS/TS, Java, Python, regex — the `TODO.md`
expansion list), so a backslash codec stacks its escape layer on the source's and
the two are indistinguishable by inspection. `var s = "C:\\Users\\me\n";` emits as
`var s = "C:\\\\Users\\\\me\\n";` — and `\\n` reads as *literal backslash-n* under
language semantics, the inverse of what the source said. The separating invariant:
**substitution never rewrites a character of the source, it only adds marks at line
breaks; backslash alters existing characters**, so the payload stops showing the
reader what the file says. It also reframes the 3.4% figure — that is a frequency,
which settled the token question correctly, but the ambiguity is concentrated in
string literals, regexes and paths, the most semantically loaded lines.

**Settled by measurement against a production payload — `\` stands.** Scanned a
real LTS C# snapshot (`project-snapshots/ThermoMapper/src_20260701_122622`, 70
shards): `\n` 51617 (87.8%), `\"` 7050 (12.0%), **`\\` 127 (0.22%)**. The
escape-layer collision is **~1.8 sites per shard, a 0.25% tax** — the collision
argument was sound in kind and an order of magnitude off in scale, and the 3.4%
figure was a PowerShell artifact (Windows paths, regex) rather than a property of
the C-family targets the concern was about.

The consequential finding is the other row: **12% of every escape in that payload
is `\"`, pure JSON residue that v3 drops by construction** — quotes need no
escaping under length-prefix framing. That is where the real legibility damage
lives (`return '\"' + text.Replace(\"\\\"\", \"\\\"\\\"\") + '\"';`), and removing
it beats any sigil choice. Confirms the length-prefix scoping written above, and
it is already banked rather than owed.

`\n` also has years of production use behind it in LTS payloads. Control Pictures
stay on file for human-inspection payloads and as the fallback if a tokenizer
measurement ever shows the substitute is ~free; no measured evidence asks for the
switch, so the tokenizer install drops from blocking to optional. Middle options
dropped as dominated (`~n` self-escapes, ~2 tokens, half-collides).

**Still the user's call: preserve vs normalize EOLs** — doc recommends preserve,
since `format-ws`'s `lf` op already owns EOL policy (default-on, run-first,
receipted in `Processing`) and LTS already splits it that way. (Reconciled on
transfer to canonical, 2026-08-10: this list also carried "a token measurement
before committing to substitution" as a second open call — stale wording left
standing when the production-payload scan settled `\`. Per the paragraph above,
that measurement is now the optional fallback trigger, not a pending decision.)

**Shared ISS-registered helper library** (user, 2026-08-04; deferred). The 6d
harmonization duplicated the same ~10-line copy-on-enrich / copy-on-mutate clone
across four mutators, and `Add-Member` is the fleet's dominant cmdlet purely
because of it. Collapse it into one helper **registered into the ISS the way
chain-executor is** — `SessionStateFunctionEntry`, unconditional, never in the
manifest or any profile. User's alternative was a method on chain-executor
itself; a sibling file is cleaner, since chain-executor's stated job is *running*
step-processors, not supplying item utilities.

Wins: one definition of the clone contract instead of six copies; one place to
swap N `Add-Member` reflection calls for a single ordered-hashtable cast
(`[pscustomobject]$ordered`), which is both more minimal and likely faster on the
hot path — **measure before claiming the speed half**; and it removes the fleet's
main obstacle to Bare.

Cost, **adjudicated 2026-08-04 (user): accepted.** Collapsing duplicated lines is
worth more than a standalone-invocation convenience that is rarely used; the
`processors/tests/*` suites will get a small wrapper that imports the helper
where the ISS would otherwise supply it. Self-contained still holds in the sense
that matters — no module imports, and an ISS-registered function exists even at
Bare.

**Companion findings (probed 2026-08-04, all verified inside a real Bare
runspace):**

- `Sort-Object` (4 sites: rs-psstrip ×3, rs-csstrip ×1) — **stability is not
  load-bearing at any of them.** Three sort by unique token offsets; the fourth
  feeds a union-merge that takes `max(End)`, which was demonstrated tie-order
  independent. So the stable-sort guarantee named in AGENTS.md, while real in
  general, is not being relied on here. Replacement:
  `List.Sort([System.Comparison[object]]{ param($a,$b) ... })` — verified to work
  in a worker runspace (scriptblock→delegate conversion is fine), in place, no
  pipeline.
- `ForEach-Object` (3 sites) — all trivially `foreach`/`for`. The format-ws case
  (`-split` → trim each → `-join`) becomes an index loop mutating in place;
  verified.
- `Add-Member` — `[pscustomobject][ordered]@{}` clone verified: preserves
  property order and the mutated key, one allocation instead of N reflection
  calls.
- **`Set-StrictMode` does not belong in processor bodies — recommend removal**
  (rs-attributes, tp-perplexity; only 2 of 7 carry it). In Bare it is a
  *non-terminating* error: the processor keeps running WITHOUT strict mode while
  writing to the error stream — and colonel clears `$Error` before each processor
  call and attributes what it finds per item, so every item would carry a
  spurious error. Beyond that it is the same category as `#Requires`, which
  colonel already REJECTS in processor bodies because the environment is
  Build-Iss's to set; a body-only fragment imposing an engine-wide setting is the
  same scope-hygiene violation, merely undetected. The strictness that matters is
  already structural — processors probe `PSObject.Properties['X']` rather than
  assuming shape — and the test harnesses set `Set-StrictMode -Version Latest` at
  script scope, which is where a development aid belongs: strictness where it
  catches bugs, without the runtime dependency where it costs.

**Declarative ISS composition** (user, 2026-08-04; deferred). Replace the
coarse `IssPreset` buckets with a capability DECLARATION — spin up runspaces
carrying exactly what is wanted, rather than Microsoft's Bare/Core/Full lumps.
Feasibility verified: `InitialSessionState::Create()` + `LanguageMode =
FullLanguage` + individually added `SessionStateCmdletEntry` items yields a
session with precisely the named commands (probe: 2 commands vs
CreateDefault2's 234; `Where-Object` worked, `Get-ChildItem` absent, and
`Get-Command` itself absent unless declared). `Build-Iss` is already the single
seam, so the change is contained.

The version worth building: **make the ISS a computed property of the plan
rather than a caller guess.** Processors already self-document "Required
IssModules" and an "IssPreset floor", and `Compile-Plan` already reads every
processor script — so colonel could take the union of declared per-processor
requirements across a profile's steps and construct exactly that session. Those
annotations become mechanical instead of advisory, and presets survive only as
named bundles expressed in terms of the primitive. Costs to scope: name →
`ImplementingType` resolution needs a catalog (CreateDefault2 serves), some
surface is functions rather than cmdlets (`SessionStateFunctionEntry`), and
providers/variables/formats are separate collections.

*Prior art worth a look when this is picked up:* PSOneTools (user's collection at
`PDenv/UserGithub/PowerShellCore/ps.core.psdig/PSOneTools/src`) — colonel already
borrowed its parallel manifest-bootstrap pattern. `Where-ObjectFast` /
`Foreach-ObjectFast` / `Group-ObjectFast` use a steppable pipeline internally to
cut per-item cmdlet overhead. Note the aim differs from this project's
convention: those optimize code that must KEEP a pipeline shape, whereas a plain
`foreach` skips the pipeline entirely and beats both. Relevant where streaming or
memory shape is required; otherwise the convention already wins. They document
the tradeoff honestly (debugging differs, `$MyInvocation` behaves differently).

**Effective-config resolver** (deferred 2026-08-04, arising from the ingest
forwarding fix): report a run's EFFECTIVE parameter values — `{ Name; Value;
Source = Caller | TargetDefault | WrapperPolicy }` — for the record, without
touching how calls are constructed. Prompted by the question "if a forwarded
param has a default, should the wrapper pass it explicitly?" Answer was no for
the CALL path: forwarding stays omission-based because that is what preserves
the tri-state (unset / set-to-the-default-value / set-explicitly) that
null-sentinel defaults need — `Invoke-Plan`'s `$MaxWorkers = $null` means
"derive the budget from item count", and any materialized value flips it to
Policy=Explicit and defeats the grading table. But the underlying want —
knowing what a run actually ran with — is real and belongs to REPORTING, not
call construction. Home is the header params block / ConfigEcho (assemble-design
§"Header elements"), admiral-owned, resolved after the fact. A resolver can
also express what materialization never could: "Auto — computed at dispatch
from item count". Declared defaults come from the AST (reflection cannot see
them: `ParameterMetadata` has no DefaultValue member) — `Get-FunctionSignature`
in `tools/rs.dev.signatures.psm1` already reports them. Reasoning recorded in
rs.core.internals' `New-ForwardedParamDictionary` .NOTES.

### F. Adjudications needed from the user (refreshed 2026-07-29)

Resolved this cycle: ignore naming adopted provisionally + implemented
(IngestMode/IgnorePatterns/IgnoreOverridePatterns/SelectionPatterns —
renameable later); ExecutiveOverrides clean break; assemble module name
adopted; entry naming narrowed (PascalCase in-memory; wire = writer);
thread idx narrowed to the arrangement layer; **6d approach adjudicated
2026-07-29** (bag-native copy-on-mutate, dual-key input, no shim —
implementation pending; envelope fate narrowed to thread rim/emission).

Still yours, none blocking current code:
- Header `flags` block: retire vs keep (assemble-design open decision 5).
- `Header.Root` emission posture vs path doctrine (open decision 6).
- tp-era envelope's wire/arrangement fate for the thread track (narrowed
  from 6d — thread-rim/emission scope, admiral/thread-milestone timing).
- Admiral: hand-off form; carried-state shape; control-flow classes/DAG;
  invocation-surface duality (Q1/4/5/6).

### Out of repo (courtesy)

- ThermoMapper repo-audit `GatherScatter` dead-cache defect (cache never
  populated; result assignment inside miss branch) — flagged for a separate
  session in that repo.

## Sequenced phases

> **2026-07-29: Phase 5 LANDED** — `rs.core.assemble.psm1` implemented per
> the design doc (fixed phases, open element model, lean-payload routing,
> RunContext stamping with reserved-name guard). `tests/assemble.tests.ps1`
> 53/53 including the **golden validation**: v3 IR vs live LTS monolith,
> content byte-exact by path key, attributes formula-equal, known deltas
> asserted as documented. Nine-suite battery **307/307**. LTS is no longer
> load-bearing for the code-track data model. Two latent finds en route:
> the if-expression single-element unroll (fixed in assemble's stream
> pass-through) and item 6d (tp-era Text/envelope contract vs descriptor
> contract in format-ws/rs-psstrip — filed). Remaining horizon: writers →
> admiral → thread track (+ 6d before strip/ws joins code-track chains).

> **2026-07-29: processor docstring audit complete** (user-requested).
> v1 API remnants (SetIssPreset fluent, RunMode) purged fleet-wide incl.
> rs-attributes' inherited copy; standardized self-doc block (Item contract /
> Position class / IssPreset floor / IssModules) — item contracts now
> declared per processor, making the 6d fault line visible in the docs;
> tp-perplexity's dual-key input verified in code; chain-executor stale path
> and rs-indent's resolved chaining contingency fixed; rs-csstrip side-effect
> + evaluation pointers added. Docstring-only; 314 asserts green across the
> touched suites (rs-indent harness note: its summary format is
> "Results: N/N passed", not the house pattern — cosmetic).

> **2026-07-29: stage-module docstring audit complete** (companion to the
> processor pass): colonel gained its missing module header; ingest synopsis
> carries the proto-admiral reframe; ignore's last ExecutiveOverride sentence
> replaced; sharding header states its thread-corpus re-disposition + queued
> writer-phase reconciliations; template's completed-integration note fixed
> and instruction-set synopses differentiated; internals cross-refs the
> wrapper documentation requirement; crawler's phantom _build.json removed.
> Docstring-only; 163 stage asserts green.

> **2026-07-29: planning/project-doc sweep** (user-requested once-over).
> Plan header + inventory now carry executed/✓ statuses; section E preview
> entry marked retired-as-concept; section F adjudications refreshed
> (resolved-this-cycle vs still-yours). Transfer audit: IR-distillation
> bullet marked DELIVERED; preview/byte-offsets row split (preview retired,
> offsets still transfer); orchestration row updated (pipeline whole through
> IR). Inversion doc status → IMPLEMENTED; stale opens struck (clean break
> done; prune×override superseded by Design v3). Assemble open decision 4
> (module name) resolved. TODO.md annotations refreshed (antisemantics
> implemented; monolith-optional delivered as IR; mvp gap = writer phase +
> 6d; language doctrine pointer). Thread-corpus work log gains the
> prerequisites-advanced entry. `reposnapshot-v3/TODO.md.md` double-extension
> accident renamed → `TODO.md` (MCP/byte-offset tooling wishlist — content
> overlaps `issues/mcp-surface.md`; fold-in left to the user).

- **Phase 0 — doc alignment.** Done this pass (see audit above).
- **Phase 1 — identity seam unit** (items 1–3; optional rider 6).
  Crawler stamps `RelativePath` + `LastWriteUtc` → ignore de-stamps →
  `Invoke-Ingest` passes descriptors → smoke test (item 8) proves the chain
  end-to-end. Un-breaks the pipeline; retires admiral residues #1/#4.
- **Phase 2 — ignore engine pass** (item 5). Needs the naming adjudication
  first. Implements Design v2 per the reconciliation touch list; tests both
  modes, override rescue, coherence validation. Composes with Phase 1's
  de-stamping (same module; either order).
- **Phase 3 — colonel AST fix** (item 4). Small, independent; test =
  tp-perplexity compiles into a plan. Can interleave with any phase.
- **Phase 4 — rs-attributes** (item 7). Tail-step contract; tests follow
  processors/tests house pattern.
- **Phase 5 — rs.core.assemble** (item 9). The gate back to new ground:
  design-seed contracts + golden validation. Entered only when Phases 1–4
  leave the substrate sound.
- **Horizon (unchanged):** writers → admiral → thread-corpus milestone.

## Work log

- 2026-07-28 — Filed; Phase 0 applied.
- 2026-07-28 — **Phase 1, crawler step landed** (item 2): file entries now
  stamp the full identity contract `{AbsolutePath; RelativePath; NodePath;
  SizeBytes; LastWriteUtc}` at walk time — `RelativePath = NodePath + name`
  (zero extra derivation), one FileInfo for size + last-write, skip reason
  renamed `FileStatReadFailed` (no consumers). Path doctrine recorded in the
  crawler docstring + assemble-design (user: absolute = ingestion reads only;
  relative = artifact-facing, root-anchored, structure encoded flatly for
  LLM-reader token economy). New `tests/crawler.tests.ps1` (house harness
  style, 27 asserts) green; real-repo smoke green (108 files, 0 skipped).
  Next: ignore de-stamp (item 3) → ingest descriptor hand-off (item 1) →
  pipeline smoke (item 8).
- 2026-07-28 — **Phase 1 COMPLETE** (items 1, 3, 8 + a bonus bug). Ignore
  de-stamped (pure filter; vestigial `RootPath` param removed — no external
  callers; fail-fast guard on pre-contract graphs). Ingest dispatches
  ItemDescriptor objects verbatim; file-read copy-on-enrich now clones ALL
  input properties (descriptor-evolution-proof). New
  `tests/pipeline.smoke.tests.ps1` (harness-as-admiral, 23 asserts) green —
  **first-ever end-to-end run of the v3 pipeline** (crawl → ignore → ingest →
  colonel → file-read). First contact flushed out a latent bug beyond the
  seam: `IgnoreCompiler.GetParentPath` declared `[string]` coerced its
  `return $null` to `''`, making Prune's ancestor walk an infinite loop —
  fixed as `[object]` return with the null-contract documented (C# lineage
  returns `string?`; the PS transliteration's typed return swallowed it).
  Also normalized an accidental operator line-split in the empty-leaf prune
  predicate. Phase 1 exit criterion met. Next: Phase 2 (ignore engine pass —
  needs naming adjudication) or Phase 3 (colonel AST fix) — Phase 3 has no
  open decisions and can proceed immediately.
- 2026-07-28 — **Phase 3 COMPLETE** (item 4). Colonel processor validation is
  AST-based: top-level param block required (chain-executor's positional
  contract), parse errors surfaced, #Requires rejection unchanged; interior
  helper functions legitimate. tp-perplexity compiles into a plan for the
  first time — thread-corpus open decision 6 resolved. New
  `tests/colonel-validation.tests.ps1` (12 asserts) green; smoke (23) +
  crawler (27) re-run green. Ignore-engine candidate naming recorded (user,
  not settled): `IngestMode` / `IgnorePatterns` + `IgnoreOverridePatterns` /
  `SelectionPatterns`. CHANGELOG 2026-07-28 section added covering Phases
  1+3. Item 6b filed (legacy colonel.tests.ps1 stale, targets v1 path).
  Remaining before Phase 5: Phase 2 (awaits final naming), Phase 4
  (rs-attributes — unblocked).
- 2026-07-28 — **Phase 4 COMPLETE** (item 7): `processors/rs-attributes.ps1`
  landed. Positional doctrine sharpened with user: language-agnostic BY
  POSITION; the invariant is "after ALL content mutators" (not just
  language-specific ones) — enrich-only step, placed in the read-only tail;
  position is a profile invariant (admiral's), processor stays
  position-ignorant. No-Content contract (pass through unenriched) makes it
  safely appendable to arbitrary profiles incl. thread envelopes. Provenance
  split documented: SizeBytes = on-disk; Attributes.* = processed content.
  **LTS defect found during parity testing**: `compression_ratio` is 0 for
  every >100-char LTS entry (MemoryStream.Length read after GZipStream.Close
  disposal → null → 0; verified in the 20260723 selfie monolith).
  rs-attributes computes the real ratio (`ToArray`) — recorded as a golden-
  compare known delta in assemble-design. Tests:
  `processors/tests/rs-attributes.tests.ps1` (34 asserts — parity formulas,
  no-Content, empty content, copy-on-enrich, colonel dispatch incl. GZip
  resolution in worker runspaces) green. Next processor item: 6c
  (FrontMatter partition in rs-psstrip).
- 2026-07-28 — **Payload doctrine recorded** (user; assemble-design §Payload
  doctrine): (a) **byte semantics, three layers never conflated** —
  SizeBytes (filesystem bookkeeping; sole consumer = pre-read eligibility) ·
  Attributes.SpanBytes (UTF-8 span of processed content; reader-navigation +
  packing semantics; landed in rs-attributes, 36 asserts green incl.
  multibyte char-vs-byte case) · rendered row `length` (writer-side encoded
  span). LTS conflated the first two (attributes.size_bytes = on-disk).
  `Partition-Files` ByteSpan property naming reconciliation queued for the
  writer phase. (b) **Lean payload, diagnostics sidecar** — failed ingests
  AND empty reads are never rendered into the payload (tree included); they
  route to a diagnostic sidecar/log with distinct reasons (read-failure
  kinds vs EmptyFile vs EmptiedByProcessing). Supersedes the earlier
  LTS-precedent default (content-less entries). Sidecar form/naming open;
  IR Skipped/Diagnostics streams are the feed. Historical note (user): the
  SizeBytes/SpanBytes distinction was a recurring assistant-confusion
  hotspot during earlier dev — filesystem vs code-analysis vs
  payload-enrichment concerns, PowerShell ingesting PowerShell; the
  three-layer doctrine is the standing disambiguation.
- 2026-07-28 — **Item 6c COMPLETE**: rs-psstrip FrontMatter partition landed.
  `_SplitCommentPopulation` interior helper (partition at parse boundary,
  Native/Derived, ScriptRequirements metadata spliced, Shebang SubKind);
  FrontMatter as named sixth kind with explicit never-strip ops case;
  run-folding flushes on non-LineComment kinds (stated run-splitter policy);
  zero frontmatter text predicates in classification; regex fallback route
  untouched (its legitimate pattern-recognition job). Suite 68 → 79 green
  (section 13: maximal-ops preservation, discriminators, run-split vs
  control, envelope stability); colonel compile + runspace dispatch
  verified. Ontology item 1 closed as fully implemented (was
  minimal-guard). Processor-work block done: Phases 3, 4, 6c all landed —
  remaining before Phase 5: Phase 2 only (awaits final naming).
- 2026-07-28 — **Phase 2 COMPLETE** (item 5). Design v3 (user): names
  adopted provisionally (`IngestMode`/`IgnorePatterns`/
  `IgnoreOverridePatterns`/`SelectionPatterns` — renameable; semantics are
  what is settled); **override collapsed into negation merge** — both
  ignore-side params are virtual root ignore sources, containers for
  positives/negations by convention, handled by the engine's existing
  merge/inheritance/annihilation machinery (no rescue layer, no prune
  special-casing; inherited canonical-gitignore constraint documented with
  the directory-negation recipe); **cross-mode params inert** (supersedes
  binding-aware throws — ergonomic mode switching); CompiledState
  regime-stamped single slot; TestPath dual truth table; RunOverrideBypass
  deleted; ExecutiveOverrides clean break. Latent bug #4 of the
  consolidation pass: Invoke-IgnoreFilter empty-leaf prune leaked
  Dictionary.Remove bool into the pipeline. New `tests/ignore.tests.ps1`
  (27); six-suite battery **205/205 green**. Unresolved tension recorded to
  admiral brief: config-driven execution will not displace direct
  bound-param invocation. **All consolidation phases complete (0–4, 6b
  pending, 6c done) — Phase 5 (rs.core.assemble) is unblocked.**
- 2026-07-28 — **Item 6b COMPLETE**: stale v1 harness `tests/colonel.tests.ps1`
  retired (its ApplyAll/KeyMatch/ResultMode API no longer exists); dispatch
  mechanics rebuilt against v2 as `tests/colonel-dispatch.tests.ps1` (20
  asserts: compile validation, index-stable ordering, Config delivery,
  serial≡parallel equivalence, _ChainHalt item-scoped skip, per-item error
  capture returning pre-step state, empty-Items envelope). Latent find #5:
  `Invoke-Plan -Items` Mandatory binding rejected `@()`, making the
  intentional count-0 early-return dead code — fixed with
  `[AllowEmptyCollection()]`. House-pattern comment pointers updated to the
  new suite. Observed, not acted: `tests/colonel-bench.ps1` is also v1-era
  stale (references removed processors/format.ps1) — refresh when perf work
  matters. **Consolidation plan fully executed: Phases 0–4, 6b, 6c all
  landed. Phase 5 (rs.core.assemble) is the sole next item.**
- 2026-07-28 — **Phase 5 scoping: LTS monolith inventory complete**
  (assemble-design §"LTS monolith inventory & v3 disposition"). Full read of
  Get-RepoSnapshot's assembly+serialization span + selfie ground truth (both
  monoliths: header+files only; flag-gated members absent; preview omitted;
  params/flags present; git_history never exercised). Key scoping facts:
  LTS sorts entries at SERIALIZATION (v3: AssemblyPolicy owns order);
  byte-offset TOC + tree.md are emission-coupled writer products
  (Get-EntryByteOffsets against live stream positions); header params block
  = ConfigEcho's ancestor; tree_diagram embeds a view in the store (removed
  from IR). Concrete IR schema drafted; entry deltas locked (binary flag
  retired to diagnostics, size_bytes → SpanBytes). New opens: flags
  retire-or-keep, Header.Root emission posture. Assemble implementation can
  begin against this inventory.
- 2026-07-29 — **6d adjudicated (user): bag-native copy-on-mutate.**
  format-ws/rs-psstrip keep their transforms byte-for-byte; only the I/O
  rim changes — clone bag, mutate Content, pass everything else through;
  dual-key input (Content|Text, tp-perplexity's pattern); no adapter shim
  (a shim would keep the envelope alive as a second contract purely to
  avoid two rim edits). Envelope cargo → attached elements. The
  thread-track envelope question shrinks to the thread rim/emission
  (out of processor scope; section F updated). 6d now has zero open
  decisions — small, interleaves freely with writer work the way Phase 3
  interleaved with consolidation.
- 2026-07-28 — **TODO item 1 (broken-reference audit) executed**, prompted by
  the user questioning "why was format.ps1 removed": it never was — never
  existed here (git-verified); `format.ps1`/`rs.core.colonel.psm1` are
  PowerShellCore-era names; the processor arrived renamed `format-ws.ps1` at
  the initial commit (still stamps `Processor = 'format'`). Sweep across all
  ps1/psm1: `format.tests.ps1` retargeted to format-ws — API-identical,
  29/29 green on first run (dormant since copy-over); `colonel-bench.ps1` is
  the sole remaining v1-era file (deferred); all other hits benign (lineage
  docs, identity strings, stripping fixtures). CHANGELOG wording corrected
  ("removed" → "never copied/renamed"). Battery now seven suites, 254
  asserts.
