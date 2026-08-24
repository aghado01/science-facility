# `rs-indent` lexical safety — here-strings and nested code — brief

**Status:** filed, not started · **Filed:** 2026-08-24 · **Track:** independent;
blocks wiring `rs-indent` into any default chain (`rs.core.user`, the selfie)
· **Doctrine:** the same hazard class rs-whitespace's `trim-inner` is already
kept opt-in for (#22 area); comment-ontology's "native AST on demand" for the
home language · **Prompted by:** attempting to wire `rs-indent` into the
ergonomic default chain, 2026-08-24.

## The problem

`rs-indent` reshapes leading whitespace per physical line. It has **no
string-literal masking** — unlike `rs-psstrip`/`rs-csstrip`, which lex via the
real PowerShell parser (`[System.Management.Automation.Language.Parser]::ParseInput`)
and refuse to touch comment/string content. `rs-indent` is gated only by file
extension (a skip list of prose formats); within an eligible file it reshapes
every line unconditionally, including lines that are *inside* a here-string —
content whose leading whitespace is literal string data, not code structure.

This is not theoretical. It is live in this exact corpus:

```powershell
# processors/tests/rs-psstrip.tests.ps1:103
$fixture = @'
<#
.SYNOPSIS
    File-level block comment. Kind: BlockComment
#>

function Invoke-Demo {
    <#
    .SYNOPSIS
        Inside function body. Kind: DocString
```

`$fixture`'s content is a *simulated PowerShell file* — its `    ` / `        `
indentation is literal string data the test asserts against. `rs-indent`
cannot distinguish this from real code and would reshape it identically.
15 here-string sites exist across the corpus today
(`rs-psstrip.tests.ps1` ×11, `rs-csstrip.tests.ps1` ×1, `rs.core.manifest.psm1`
×1 — `$script:TreeTemplate`, mostly column-0 so lower-risk — plus 2 more not
yet inventoried outside `processors/`).

## Why this wasn't caught earlier

`rs-indent` has never been chain-wired. It has unit tests (dot-invoked
directly, synthetic fixtures) but has never run over real, lexically-rich
source — the same pattern this session's other findings trace back to
(narrow/synthetic testing missing what a full-pipeline or real-corpus run
surfaces immediately). The parallel to `trim-inner` is exact: that op is kept
opt-in specifically *because* `rs-whitespace` "is lexically blind — no string
masking, unlike rs-psstrip/rs-csstrip — so it cannot tell a literal from
code" (decision #16 in the registry). `rs-indent` has the identical blindness
but no equivalent flag anywhere in its own documentation.

## The design direction (user, 2026-08-24) — not a masking fix, a visitor

The instinct to reach for is "mask here-strings and skip them," matching
`rs-psstrip`'s treatment of comments. **That is explicitly not what is
wanted.** The user's design: `rs-indent` should be lexically aware of
here-string boundaries, but instead of skipping their interior, it should
**recurse into them as their own nested scope** — normalize the outer
structure, then visit each here-string's interior as its own sub-document,
normalize that too (its own GCD/baseline), splice back. A **visitor**, not a
mask.

Infrastructure already exists to build this on: `rs-psstrip` already uses the
real parser/AST for this exact language, per comment-ontology's stated
doctrine ("thoughtful-regex processors are the default for new languages,
native AST on demand" — PowerShell already gets the AST treatment). The AST
gives here-string nodes as distinct extents for free; a visitor doesn't need
to hand-roll here-string detection.

**The fork that changes scope materially**, surfaced but not resolved:
PowerShell has two here-string kinds.

- `@'...'@` (single-quoted) — pure literal text. Recursing into it is the
  simple case: re-indent its own lines as a self-contained sub-document. This
  is also the **only** kind present in this corpus today (all 13 non-manifest
  sites are `@'`).
- `@"..."@` (double-quoted/expandable) — can contain `$(...)` subexpressions
  holding arbitrary nested *code*. Under the visitor framing, a
  subexpression's content isn't string data at all — it wants a **full
  recursive normalization pass**, structurally identical to the top level,
  not a text-block visit. This is a second, harder recursion case.

Open call: is v1 single-quoted-only (matches this corpus, self-contained,
buildable without touching the interpolation grammar), with expandable
here-strings' `$(...)` handling filed as its own follow-on? Or both from the
start? **Not decided here** — this brief records the tension, not the answer.

## What already landed, unblocking a piece of this independently

Physical-line splitting was pulled out and shipped separately (2026-08-24,
same day): `rs-indent` no longer assumes bare `\n` — it recognizes the same
terminator vocabulary as `rs-whitespace`'s `lf` op (CRLF/CR/LF/NEL/LS/PS/VT/FF),
preserving each line's original terminator bytes rather than folding them
(folding stays `rs-whitespace`'s job). This is what makes `rs-indent →
rs-whitespace` chain ordering viable at all — previously `rs-indent` silently
saw only the first physical line of any file using a non-`\n` terminator
exclusively. `processors/tests/rs-indent.tests.ps1` §22 (10 new asserts).
This piece needed no lexical awareness — it's orthogonal to the here-string
problem — and shipped independently of it. Battery: **23 suites · 1403
passed · 0 failed**.

## What remains open — genuinely unresolved, not just unbuilt

- **Nested-scope baseline policy.** When a visitor recurses into a
  here-string's interior, what does it normalize *relative to*? GCD inferred
  purely from the block's own internal lines (ignoring the outer file's
  indentation), or anchored to the here-string's own opening column? This
  determines whether a here-string's *relative* internal structure is
  preserved when the whole block sits at a different absolute depth than its
  simulated content implies (the `$fixture` example above: the fake `function
  Invoke-Demo {` line is at depth 0 inside the string, but the string itself
  might someday be nested inside a real function).
- **Whether `$(...)` subexpressions in expandable here-strings get the full
  recursive-as-code treatment in v1**, per the fork above.
- **Whether this needs its own token-classification pass or can share
  `rs-psstrip`'s existing AST walk** — a shared lexing helper would avoid
  parsing the same file twice per chain run, but `rs-psstrip` is a comment
  stripper and `rs-indent` is a whitespace reshaper; whether their AST needs
  overlap enough to share code, or should just both call
  `[Parser]::ParseInput` independently, is unresolved.

## Non-goals

- Markdown fenced-code-block awareness — already filed as a `rs-indent`
  FUTURE note in its own docstring, unrelated to this gap.
- Extending masking/visiting to non-PowerShell languages — this brief is
  scoped to the home language, matching where the AST infrastructure already
  exists.

## Exit gate (for whenever this is picked up)

- A here-string fixture with meaningfully-indented interior content — like
  the corpus's own `$fixture` in `rs-psstrip.tests.ps1` — survives `rs-indent`
  with its interior reshaped *consistently with itself* (own baseline) and
  never confused with the outer file's structure.
- The corpus's 15 known here-string sites, run through `rs-indent`, produce
  output that a human reviewer confirms is not corrupted (spot-check, not
  full formal verification — there is no ground truth to assert against
  automatically for "should indentation-inside-a-string look like this").
- Only then does `rs-indent` (with whatever op set is chosen) get wired into
  `rs.core.user`'s and the selfie's default chains.
