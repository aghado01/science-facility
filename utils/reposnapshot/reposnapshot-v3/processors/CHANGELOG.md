# Changelog — processors/

## 2026-07-22 — rs-psstrip.ps1 — tolerant routing, here-string masking, shebang

- **Route gate inverted per the tolerance constraint**: the token walk now runs even when
  parse errors exist (the tokenizer is error-recovering; `ParseErrors` is reported on the
  envelope either way). The pseudo-AST regex fallback engages only on string-terminator
  breakage — ErrorIds `TerminatorExpectedAtEndOfString` (no closer) and
  `WhitespaceBeforeHereStringFooter` (indented closer), both of which swallow the file
  tail into one string token — or via new `Config.ForceRegexFallback`.
  `FallbackMode = 'regex'` now appears only when the fallback actually ran.
- **Here-string masking in the fallback** (`Config.MaskHereStrings`, default `$true`):
  here-strings are code payload, not comments — sentinel-masked (PUA) before the
  fallback regexes run, restored after span rebuild. Terminated here-strings mask
  exactly; a broken opener masks through a lenient (indented) closer when present, else
  to EOF — recovering stripping *beyond* the breakage, which the token path can only
  under-strip. Set `$false` to let the fallback process here-string interiors.
- **Line-1 shebang** joins `#Requires` as protected frontmatter on both routes (parity
  with LTS stage 4).
- Known limitation: ordinary single/double-quoted literals are not masked in the
  fallback (rarely-reached route); revisit if fallback usage grows.
- **`rs-psstrip.tests.ps1`** — section 3 rewritten for tolerant routing (+forced
  fallback), section 11 extended (shebang, forced-fallback case-guard regression),
  section 12 added (here-strings: clean-path pass-through, broken-here-string
  auto-routing with recovery, `MaskHereStrings` override). 68/68 passing.

## 2026-07-22 — rs-psstrip.ps1 — FrontMatter protection in the AST path

- **`#Requires` tokens excluded from the comment population before classification**
  (`-notmatch '^#requires\b'` on the `$commentTokens` filter). Protection by partition,
  per script-surface's `Invoke-Parser` (ps.core.psdig): the token never becomes a strip
  span, so its bytes survive the rebuild on every op combination. Previously the AST
  path classified `#Requires` as LineComment/CommentBlock and stripped it under default
  ops — only the regex fallback guarded it.
- **Fallback guards made case-insensitive**: `#(?!requires\b)` → `#(?!(?i:requires)\b)`
  in both `$rxLine` and `$rxInline`. The patterns compile with `RegexOptions None`
  (case-sensitive), so the canonical `#Requires` capitalization was previously stripped
  by the fallback despite the guard.
- Run-folding nuance: a `#Requires` between comment lines no longer bridges a
  CommentBlock run (exclusion splits it into isolated LineComments). Accepted —
  taxonomy distinction only; default ops strip the neighbors either way.
- **`rs-psstrip.tests.ps1`** — new section 11 (FrontMatter): 8 assertions covering AST
  default-ops preservation, lowercase form, sandwich run-split, and fallback-path
  preservation with canonical capitalization. 51/51 passing.

## 2026-04-22 — file-read.ps1 — \_ChainHalt on failure

- **`_ChainHalt = $true` stamped on both error exit paths**: NUL/binary content
  and read exceptions both now set `_ChainHalt` on the returned `PSCustomObject`
  in addition to `ReadError`. Downstream chain executor short-circuits remaining
  processors without needing to inspect the error type.
- **Shallow copy taken up-front**: `AbsolutePath`, `SizeBytes`, `RelativePath`,
  `NodePath` are copied from `$Item` into a fresh `PSCustomObject` before any I/O,
  guaranteeing a well-formed return object on every exit path.
- Size ceiling and extension blacklist are enforced upstream by `Invoke-IgnoreFilter` —
  file-read's NUL byte guard is the final binary slip-through check.
- `processors/format.ps1` renamed to `format-ws.ps1` i.e. "format whitespace"

## 2026-04-14 — chain-executor.ps1 + file-read.ps1

- **`file-read.ps1` introduced** — reads file bytes via `ReadAllBytes`, performs
  NUL byte / binary guard, decodes as UTF-8, and returns an enriched `PSCustomObject`
  with a `Content` property. Loaded into `rs.core.colonel.v2.psm1` runspace ISS
  as the first processor in the default chain.
- **`chain-executor.ps1` introduced** — always included in colonel runspace ISS;
  handles sequential execution of processor chains constructed from colonel's
  profile-based plan. Loaded and invoked by `Invoke-ChainExecutor` inside each worker.

## 2026-04-10 — rs-psstrip.ps1 — regex fallback on parse errors

- **Parse errors no longer cause early-return with text preserved.**
  When `Parser.ParseInput()` reports errors, the processor now activates a
  regex fallback path that identifies and strips comment spans structurally,
  producing the same result shape as the AST path.
- **Fallback op coverage**: block comments (`(?s)<#.*?#>`), standalone `#` lines
  with CommentBlock run-detection (same 2+ contiguous logic as AST path),
  and inline comments. `#Requires` lines are excluded from stripping.
  DocStrings cannot be distinguished from BlockComments without scope extents;
  either op active (`block-comments` or `doc-strings`) will strip `<#…#>` spans.
- **Envelope additions when fallback is active**: `ParseErrors string[]`,
  `FallbackMode = 'regex'`. These fields are absent on clean-parse runs.
- **`rs-psstrip.tests.ps1`** — section 3 updated from "parse error early return"
  to active fallback verification: 7 assertions covering `ParseErrors`,
  `FallbackMode`, comment stripping, and code preservation. 43/43 passing.

## 2026-04-10 — format.ps1 / rs-psstrip.ps1 — bug fixes

- **`format.ps1` — `max-blank-2` / `max-blank-1` semantics aligned to VSCode convention**:
  `max-blank-N` means _keep at most N blank lines_ (number = retained maximum, matching
  `editor.maxBlankLines`). `max-blank-2` collapses 3+ blank lines → 2 (`(\n){4,}` → `\n\n\n`);
  `max-blank-1` collapses 2+ blank lines → 1 (`(\n){3,}` → `\n\n`). Previously the regex
  and test expectations were misaligned with this intent.
- **`format.ps1` / `rs-psstrip.ps1` — empty-ops pass-through**: `Operations = @()`
  (explicit empty array) now passes text unchanged; default ops only apply when
  `Operations` key is absent from Config. Changed from count-based check to
  `$Config.ContainsKey('Operations')`.
- **`format.tests.ps1`** — stale `'tp-generic'` assertion corrected to `'format'`;
  `max-blank-2` test expectation and section header corrected to match VSCode-aligned
  semantics (3 blank lines → 2 blank lines in output).
- **`rs-psstrip.tests.ps1`** — `PSNoteProperty`→bool cast fixed to
  `$null -ne $rBroken.PSObject.Properties['ParseErrors']`.
- All tests passing: `format.tests.ps1` 29/29, `rs-psstrip.tests.ps1` 40/40.

## 2026-04-10 — rs-indent.ps1 — initial implementation

- **`rs-indent.ps1` introduced** — RS-scoped indentation normalizer.
  Four independently selectable ops applied in fixed internal order:
  `strip-common` (frame shift), `detab` (O(n) sweep: expand tabs, accumulate
  depths), `min-indent-2` (GCD-rescale to TargetUnit), `tabify` (spaces→tabs).
  `detab` auto-activates as precondition for `min-indent-2` and `tabify`.
  No default ops — processor is wholesale opt-in.
  Skip list for prose/markup extensions returns envelope with `Skipped = $true`.
  `TargetUnit` config param (default 2) controls tab expansion and rescale target.
  Self-contained — does not import or depend on `normalize-indentation.psm1`.
- **`rs-indent.tests.ps1` introduced** — 20 test cases covering all ops,
  combinations, skip list, item unpacking, TargetUnit, and edge cases.
  39/39 passing.

## 2026-04-09 — format.ps1 — renamed from tp-generic.ps1

- **`tp-generic.ps1` renamed to `format.ps1`** — processor is pipeline-agnostic
  (serves both TP and RS callers); the `tp-` prefix implied TP exclusivity which
  was inaccurate. `Processor` field in return envelope updated from `'tp-generic'`
  to `'format'`.
- **`tp-generic.tests.ps1` renamed to `format.tests.ps1`** accordingly.
- **Docstring updated**: `.SYNOPSIS` rewritten; pipeline suitability table added
  per op (TP-safe vs RS opt-in).

## 2026-04-09 — processors/tests/ — initial test harnesses

- **`rs-psstrip.tests.ps1` introduced** — unit harness for `rs-psstrip.ps1`.
  Covers item unpacking, early-return paths (empty text, parse errors), default ops,
  each op kind in isolation, BlockComment/DocString extent distinction, CommentBlock
  reclassification, isolated LineComment, IncludeMeta=false, and empty-ops no-op.
- **`tp-generic.tests.ps1` introduced** — unit harness for `tp-generic.ps1`.
  Covers all 11 op keys individually, item unpacking, default ops, IncludeMeta=false,
  empty ops, and empty text.

## 2026-04-09 — tp-generic.ps1

- `Set-StrictMode` removed — StrictMode is the host module's responsibility.
- Docstring updated: IssPreset references `Standard`/`Minimal` → `Full`/`Bare`;
  processor self-documentation block added (IssPreset floor, RunMode, Config shape).

## 2026-04-08 — tp-generic.ps1

- `[Parameter(Mandatory)]` removed from Item parameter (ISS-worker-safe contract).
- `[CmdletBinding()]` commented out (inert but preserved for reference).
- Processor self-documentation block added to docstring.

## 2026-04-09 — rs-psstrip.ps1

- `Set-StrictMode` removed — StrictMode is the host module's responsibility.
- Config migrated from five boolean keys (`StripBlockComments`, etc.) to
  `Operations` string array (`block-comments`, `doc-strings`, `comment-blocks`,
  `line-comments`, `inline-comments`). Default strips all structural kinds; inline kept.
- Both early-return paths (empty text, parse errors) now return `Operations = @($ops)`.
- Docstring updated throughout; `.NOTES` host guidance updated for new Config shape.

## 2026-04-08 — rs-psstrip.ps1 — initial implementation

- AST-based PowerShell comment stripper.
- Five comment kinds: BlockComment, DocString, CommentBlock, LineComment, InlineComment.
- Classification is AST-extent-based (BlockComment vs DocString) and line-adjacency-based
  (LineComment vs CommentBlock). Span reconstruction operates on character offsets.
- `[CmdletBinding()]` and `[Parameter(Mandatory)]` absent — ISS-worker-safe from the start.
- Config shape at introduction used boolean keys (migrated to Operations in 2026-04-09).
