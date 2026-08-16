# LTS StripComments corrupts string literals containing comment-like sequences

**Status:** fixed 2026-07-22, in repo since interim init (f92b686) · **Severity:** critical (silent data corruption in snapshot output) · **Filed:** 2026-07-22 by review session

## Problem

`Normalize-FileContent` stage 4 in `RepoSnapshotLts.psm1` (line ~796) strips PowerShell block
comments with a bare regex over raw text:

```powershell
$text = $text -replace '(?s)<#.*?#>', ''
```

The regex is not string-literal aware. Any `<#`…`#>` sequence inside a quoted string is eaten.

## Proven instance (selfie snapshot 20260722_195015)

Source `reposnapshot-v3/processors/rs-psstrip.ps1:122`:

```powershell
$rx = [regex]::new('(?s)<#.*?#>', 'None')
```

Snapshot shard s001 contains:

```powershell
$rx = [regex]::new('(?s)', 'None')
```

An agent reviewing from the snapshot sees a phantom bug (empty regex) that does not exist in
source. The LTS module itself contains the same literal at line 796, so every self-snapshot
corrupts that line too.

## Worse general case

The replace is global and lazy: a string-embedded `<#` with **no** `#>` in the same literal will
pair with the next `#>` anywhere later in the file, deleting an arbitrary span of real code.
The same defect class applies to the `.cs` (`/*…*/` in strings), `.py` (`"""…"""` in strings),
and `.js/.ts` branches.

## Fix options

1. **Preferred:** replace stage 4 for PS files with tokenizer-based stripping — the AST/token
   path already implemented in `reposnapshot-v3/processors/rs-psstrip.ps1` classifies comment
   tokens via `[Parser]::ParseInput` and never touches string literals. Port it into
   `Normalize-FileContent` (or call it) for `.ps1/.psm1/.psd1`.
2. Minimum: mask string literals (sentinel swap) before the comment regexes, restore after —
   same `_MaskByRegex` pattern used in `tp-perplexity.ps1`.
3. Stopgap: default `StripComments` to `$false` and document the hazard.

For non-PS languages regex stripping can stay short-term, but apply option 2 masking there too.

## Design constraint (added 2026-07-22, post-filing)

Ingestion must tolerate broken/unparseable code — snapshots are frequently prepared for debug
requests, so processing never gates on validity. Implications for the fix:

- Do NOT gate token-based stripping on `$errors.Count -eq 0`. `[Parser]::ParseInput` returns
  tokens and errors separately and the tokenizer is error-recovering: parse errors almost never
  mean "no usable tokens." Use the Comment tokens whenever tokenization produced them.
- The catastrophic tokenizer case (unterminated string/here-string swallowing the file tail into
  one string token) must degrade to **under-stripping** (comments retained) — never span
  deletion. Under-strip is the acceptable failure direction; corruption is not.
- Pure-regex stripping is last resort only, and must mask string literals first.
- Stripping is **language-specific by architecture** — see `issues/reposnapshot/design/comment-ontology.md`.
  Do not grow the extension-switch in `Normalize-FileContent`; the PS fix should be the
  per-language processor path. Two PS-specific requirements: (a) `#Requires` and a line-1
  shebang lex as ordinary Comment tokens — the token path must classify them as
  `frontmatter` and never strip them (the regex paths' `#(?!requires\b)` guard has no token
  equivalent today); (b) Authenticode `# SIG # Begin/End signature block` runs are a
  distinct strippable kind and a large token win.

## Acceptance

- Round-trip test: snapshot `rs-psstrip.ps1` with `-StripComments $true`; shard content must
  retain `'(?s)<#.*?#>'` intact.
- Pester case for a file where a string-embedded `<#` has no matching `#>` in the same string
  (span-deletion case).
- Real doc comments (`<# .SYNOPSIS … #>`, standalone `#` lines) still stripped.
- Tolerance case: a file with deliberate syntax errors (unbalanced brace, half-written function)
  still gets comments stripped via tokens, and its code content survives byte-for-byte.

## Work log

### 2026-07-22 — fix session (Claude)

**Changes**

1. `RepoSnapshotLts.psm1` — `Normalize-FileContent` stage 4 rewritten:
   - **PS branch** (`.ps1/.psm1/.psd1`): both regexes replaced with a
     `[Parser]::ParseInput` token walk. Only Comment-token extents are deleted, so
     string/here-string content is untouchable by construction. Whole-line comments
     consume their indentation and trailing newline; inline `#` after code is kept
     (parity with the prior line-anchored regex). Frontmatter is never stripped:
     `#Requires` directives and a line-1 shebang. Per the post-filing design
     constraint, stripping is NOT gated on parse errors — the error-recovering
     tokenizer's output is used as-is, and the worst tokenizer failure mode
     degrades to under-stripping, never span deletion.
   - **.cs / .py / .js-family branches**: sequential regexes replaced by a single
     combined string-or-comment alternation scan with a MatchEvaluator. Because
     strings and comments are alternatives of one left-to-right scan, a comment
     marker inside a string (or a quote inside a comment) can never pair across
     boundaries. This was chosen over the brief's suggested `_MaskByRegex`
     sentinel masking: bare string-regex masking can still mis-pair a quote inside
     a block comment and corrupt in the opposite direction; the combined scan is
     immune and needs no restore pass. Behavior deltas: string literals containing
     comment markers now survive (the fix); `.py` triple-quoted literals not in
     statement position now survive (previously deleted as pseudo-docstrings);
     `.py` line-1 shebang kept; standalone-only line-comment stripping parity
     retained (trailing comments after code still kept).
2. `reposnapshot-v3/rs.core.sharding.psm1:29-30` — enabling fix: inner imports
   used `$PSScriptRoot\reposnapshot-v3\rs.core.{hash,lsh}.psm1` (doubled path
   segment), which made `RepoSnapshotLts.psm1` fail to import entirely on this
   machine. Corrected to sibling paths.
3. `tests/RepoSnapshotLts.StripComments.tests.ps1` — new Pester suite (9 cases):
   dynamic round-trip of every `[regex]::new` literal in rs-psstrip.ps1, the
   span-deletion case, doc/standalone stripping with `#Requires` + inline kept,
   here-string protection, the tolerance case (syntax-error file still stripped
   via tokens, code survives), shebang frontmatter, and the .cs/.py/.js
   string-protection cases. Two authoring hazards discovered: Pester 6 name
   templating chokes on literal angle-hash pairs in `It` names, and the test
   file's own header must not spell the block-comment closer inside a block
   comment (it terminates early — the very defect under test).

**Verification**

- Pester 9/9 green (Pester 6.0.0, PS 7.6.0).
- E2E: `Get-RepoSnapshot` over a temp dir containing rs-psstrip.ps1 with
  `-StripComments $true` → snapshot JSON retains `[regex]::new('(?s)<#.*?#>', 'None')`
  (1 hit) and contains zero instances of the corrupted `new('(?s)', 'None')` form.
  This exercises the serialized-function parallel runspace path.
- Selfie-class check: the LTS module itself normalizes with its own pattern
  literals intact.

**Notes / not done**

- The extension switch was not grown; per-language processor routing
  (comment-ontology) remains the v3 architectural path per the design constraint.
- Authenticode `# SIG #` runs are stripped here as ordinary standalone comment
  lines — no distinct kind in LTS; classification lives in the v3 ontology.
- **No commit made**: no functioning git repo exists — `D:\aghado01\.git` is an
  empty directory, and neither `utils\` nor `reposnapshot\` is a repo. Where to
  init (utils/ per roadmap vs reposnapshot/ standalone) is a user decision.
