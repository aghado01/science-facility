# Comment ontology and the language-specific strip contract

**Status:** design note · **Filed:** 2026-07-22 from review discussion

## Why stripping matters

Comment stripping is a first-order token-economy lever for snapshots, and separately a
*de-biasing* tool: removing potentially inaccurate/outdated/misleading comments forces the
reader (agent) to reason over the code itself, and removes the reasoning tax of interleaved
comment blocks.

## Architecture principle

**The ontology is the shared vocabulary; classification is processor-private and
language-specific.** The `Operations` config contract already spoken by `rs-psstrip` /
`rs-csstrip` is the cross-language interface. Each language gets its own processor that owns
recognition of the kinds using whatever machinery fits (real tokenizer/AST for PowerShell,
masked pseudo-AST regex elsewhere). `Normalize-FileContent`'s extension-switch in the LTS is
the anti-pattern version; LTS stage 4 should dispatch to per-language processors.

Rationale (verified 2026-07-22): the PS tokenizer lexes shebang, `#Requires`, ordinary
comments, inline comments, and Authenticode `# SIG #` lines all as Kind=`Comment` — zero
semantic discrimination. Only language knowledge separates directive from noise.

## Ontology kinds

| Kind | Examples | Default policy |
|---|---|---|
| `frontmatter` / directive | PS `#Requires`, shebang `#!`; Python coding cookie, `# type:`, `# noqa`, `# pylint:`, `# fmt:`; JS/TS `// @ts-*`, `eslint-disable`, `/* istanbul */`, `//# sourceMappingURL=` | **never strip** |
| `doc-strings` | PS comment-based help `<# .SYNOPSIS #>` in body, C#/TS `///` + `/** */`, Python docstrings | strip in debias mode, keep in api mode |
| `block-comments` | standalone `<# #>`, `/* */` | strip |
| `comment-blocks` | contiguous runs of standalone line comments | strip |
| `line-comments` | single standalone line comment | strip |
| `inline-comments` | trailing `# ...`, `// ...` after code | strip (configurable) |
| `signature-blocks` | PS Authenticode `# SIG # Begin/End signature block` (large base64) | strip aggressively — big token win |
| `region-markers` | `#region`, `//region` | strip (IDE garbage; already LTS stage 3) |
| *(future)* commented-out code | comment spans that parse as code | candidate for debias mode |

Not comments — must never be touched by strippers: C# `#region`/`#pragma`/`#if` preprocessor
directives; PS `using` statements.

## Mode presets (ops bundles)

- **economy** — strip everything except `frontmatter` (+ `doc-strings` optionally kept)
- **debias** — economy + `doc-strings` + `inline-comments`: code-only reading
- **faithful** — strip nothing; normalization stages only

## Known gaps (action items)

1. **DONE 2026-07-22** (minimal fix: `#Requires` excluded from the comment population in
   the AST path; fallback guards made case-insensitive — they compiled with
   `RegexOptions None` and only protected lowercase `#requires`; tests section 11 added,
   51/51. Shebang/`signature-blocks` remain open — see items 2 and 5.)
   ~~`rs-psstrip.ps1` AST path has no `frontmatter` kind~~ — classified `#Requires` as
   LineComment (or folds it into a CommentBlock run in the file-header case) and strips it
   under default ops. The regex **fallback** paths guard with `#(?!requires\b)` (lines 144,
   208), and the processors CHANGELOG's "`#Requires` lines are excluded from stripping"
   claim refers to that fallback only. Net behavior is inverted from intent: broken code
   keeps `#Requires`, clean code loses it. Fix: first check in the classification loop —
   `^#requires\b` (case-insensitive) or line-1 `^#!` → `Kind = 'FrontMatter'`, excluded
   from run-folding, never stripped. Add a clean-parse preservation assertion to
   `rs-psstrip.tests.ps1` (none exists today). Note: the `frontmatter` Operations kind
   appears in the colonel-sanders design notes (old PowerShellCore location) only as a
   conceptual `rs-mdstrip` example — this item is its first real implementation.

   **Design clarification (user, 2026-07-28) — promotion is the requirement,
   not a nicety:** the AST route implements *lexical tokenization* — the
   ontology kinds are named objects produced by classification, and all
   downstream treatment (strip ops, reporting, future canonicalize) filters
   **by kind name, never by raw text content**. Pattern recognition against
   text is the *fallback route's* job (regex path, unparseable files only).
   The current `^#requires\b` population-exclusion guard is therefore a
   stopgap inside the tokenized route: frontmatter is invisible instead of
   named. Target state: classify to `Kind = 'FrontMatter'` (partition, per
   the psdig lineage below), default ops never strip it, run-folding treats
   it as a run-splitter explicitly. Filed in the consolidation plan.

   **Canonical mechanism (source lineage):** `Invoke-Parser` in
   `C:\Users\azrie\PDenv\UserGithub\PowerShellCore\ps.core.psdig\script-surface\src\ast-primitives.psm1`
   protects `#Requires` by **partition, not guard**: post-parse, Comment tokens matching
   `^#Requires\b` are promoted out of the native token stream into a Derived stream as
   `ScriptRequirements` tokens (Kind reassigned — derived kind strings must not collide
   with `[TokenKind]` names; Text/Extent retained; `$ast.ScriptRequirements` typed
   metadata spliced in). Promoted tokens are invisible to all downstream comment
   classification. rs-psstrip lifted the ParseInput core but not this layer. Minimal
   port: add the `^#requires\b` exclusion to the `$commentTokens` filter (strip spans
   only arise from classified comment tokens, so the bytes survive automatically).

   **Architectural extraction (read 2026-07-28, for the faithful transfer):**
   the design intent that was lost (user: "didn't make its way through the
   transfer — I got more regex-like matching in the AST path despite myself"):
   - *Layer contract*: ast-primitives is Layer 1 — parse + irreducible token
     ops only; no judgment, no consumer-shaping. `Invoke-Parser` returns one
     normalized shape `{Ast; Native{Tokens}; Derived{Tokens}; Errors; IsValid}`
     with PSTypeName-stamped containers.
   - *Partition at the parse boundary*: the text match (`^#Requires\b`)
     happens **exactly once, at the promotion site** — the sanctioned place
     where language knowledge converts a pattern into a TYPE. Downstream
     consumes named streams / kind names; promoted tokens are structurally
     absent from the Native stream, so no consumer ever needs a guard.
   - *Derived tokens are enriched objects*, not exclusions: Kind string +
     Text/Extent + spliced typed metadata (`RequiredPSVersion`,
     `RequiredModules`, `RequiredAssemblies`, `RequiredPSEditions`,
     `IsElevationRequired`) — the ready-made input for reporting and the
     `canonicalize-frontmatter` op.
   - *rs-psstrip's deviation*: the text predicate migrated from the parse
     boundary into the consumer (classification filter) — mechanism kept,
     layering lost. The 6c fix is to restore the boundary, not merely rename
     the guard.
   - *Adaptation constraint*: rs-psstrip is a body-only ISS processor
     (Required IssModules: none) — the partition lives as an interior helper
     function, which colonel's validation permits as of the 2026-07-28 AST
     fix (it was regex-rejected before). ~~Alternative (open choice): promote
     ast-primitives into an rs.core module~~ — **adjudicated (user,
     2026-07-28): self-contained interior helper.** PowerShell's prominence
     in reposnapshot processing is contingent (much was authored in PS during
     RS's development), and the general script-surface work doesn't matter
     for much else right now; the partition is lifted as a special-case
     handling of PowerShell's #Requires/comment-syntax collision, not as a
     shared-library dependency.

   **Language-expansion doctrine (user, 2026-07-28) — the AST/regex-fallback
   hierarchy is a PowerShell-route fact, not a pipeline template.** As
   language support expands, with limited processing needs per language and
   no PS-style directive/comment collision, the default is **purpose-built
   language-specific processors with thoughtful regex** (the pseudo-AST of
   the ground rule above), escalating to implementing or importing a
   language's native AST parser only when more sophisticated needs motivate
   it. "It's a fluid enterprise" — per-language pragmatism, demand-driven,
   consistent with the "whatever machinery fits" ground rule. Within
   rs-psstrip the AST-primary/regex-fallback hierarchy stays firm; it is not
   a mandate on future language processors.
   Behavioral nuance to test: a `#Requires` between comment lines currently bridges a
   CommentBlock run; exclusion splits the run. The Derived token's typed metadata is
   also the ready-made basis for canonical frontmatter re-emission (item 3).
2. Add `signature-blocks` kind to rs-psstrip (detect `# SIG # Begin/End signature block`
   runs). Purpose is **independent controllability and taxonomy**, not stripping per se —
   SIG runs already fall to `comment-blocks` under default ops in both LTS and rs-psstrip;
   the distinct kind lets a keep-comments profile still drop signatures (and reporting
   count them separately).
3. Optional `canonicalize-frontmatter` op: re-emit `#Requires` from AST metadata
   (`$ast.ScriptRequirements`). This is a *regularization* op (reduce statistical
   variability), NOT a fidelity default — bytes are the artifact of record and are never
   regenerated from the tree by default. Nonessential since the partition fix landed.
4. rs-csstrip: confirm `#pragma`/`#region` untouched (they are — it only handles `/* */`
   and `//` forms) and consider `frontmatter` for `// <auto-generated>` headers (decide:
   directive or strippable?).
5. Future processors (Python, JS/TS) implement the same `Operations` vocabulary with the
   directive lists above.
6. **DONE 2026-07-22** — rs-psstrip brought to parity with (and past) LTS stage 4: token
   walk runs despite parse errors; pseudo-AST fallback auto-engages only on
   string-terminator breakage (`TerminatorExpectedAtEndOfString` /
   `WhitespaceBeforeHereStringFooter`) or `Config.ForceRegexFallback`; here-strings are
   sentinel-masked in the fallback by default (`Config.MaskHereStrings = $false` to
   override — they're code payload, not comments) with lenient-closer recovery for
   broken here-strings; line-1 shebang aligned with `#Requires` on both routes. 68/68.
   Remaining limitation: ordinary quoted literals are not masked in the (now
   rarely-reached) fallback — revisit if fallback usage grows.

## Whitespace regularization policy (stated by user, 2026-07-22)

Intent: remove unnecessary whitespace; collapsing 2+ blank lines is fine — blank-line
runs are rarely meaningful, **including inside here-strings and string literals**.
Snapshots are for reading, not rehydration; regularization wins by default.

Known theoretical rehydration-breakers — note-and-revisit only if rehydration ever
becomes a use case:

- embedded diffs/patches (hunk line counts break when blank lines collapse)
- markdown hard-breaks (two trailing spaces) killed by `trim-trailing`
- tab-semantic content (Makefile recipes) under detab/tabify
- fixed-width aligned data under `trim-inner`

If one of these surfaces in practice, the answer is a fidelity-tier ops profile (safe
ops only), not abandoning regularization.

## Invariant (shared with lts-stripcomments-string-corruption.md)

Failure direction: **under-strip is acceptable, corruption never.** Tolerant ingestion of
broken code takes precedence over strip completeness.
