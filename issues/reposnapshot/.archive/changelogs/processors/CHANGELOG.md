# Changelog — processors/

## 2026-08-17 — rs-attributes.ps1 → rs-content_meta.ps1 (rename; named after the psr block it feeds)

- `git mv` of the processor and its suite; chain keys / paths / precedent
  mentions in sibling processors, tests, AGENTS.md, live briefs, ledger 11b
  follow. Enrich-only — no `Processing` tag to rename. Metrics untouched.
- Header: states it is the in-memory source of psr `content_meta`
  (`schema/psr.header.json` maps `Attributes.*` → wire sub-fields); the stale
  "SpanBytes IS the right input for shard packing budgets" line corrected —
  superseded by ledger #39 (packing measures rows via the container), and
  SpanBytes is not a `content_meta` sub-field (`content_bytes` is that fact).
- **Element renamed too (follow-up, same day):** `Attributes` → `ContentMeta`
  in memory. One concept, three casings by convention: wire `content_meta`
  (snake) · in-memory `ContentMeta` (Pascal) · processor `rs-content_meta`.
  psr `source` paths, contract notes, golden/mutator-chain/crawler tests
  follow (crawler gains a "no ContentMeta field" reservation assert alongside
  the existing "no bare Attributes" one — `FsAttributes` is the crawler's).
  Ledger #26 amended in place; decision unchanged.

## 2026-08-17 — format-ws.ps1 → rs-whitespace.ps1 (rename; code-lane name)

- `git mv` of the processor and its suite (`format.tests.ps1` →
  `rs-whitespace.tests.ps1`); `Processor = 'rs-whitespace'` in the `Processing`
  record (siblings self-name after their file); chain-map keys in tests follow.
  Synopsis now states the lane (code ingestion, not markdown — ledger #21) and
  that whitespace normalization is a lane requirement: `lf` is what lets the
  container's codec count on LF-only content. Transforms untouched.
- Left as is: `tests/colonel-bench.ps1` (already pointed at a PowerShellCore-era
  path; not in the battery); historical mentions in design notes / plans.

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
