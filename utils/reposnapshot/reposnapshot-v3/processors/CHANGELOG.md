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
