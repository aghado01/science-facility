---
format: Structural
exported_at: 2026-08-25T08:10:20.5682669Z
exchanges: 9
user_label: Aipithicus
sessions:
  - f646320e
models:
  - claude-opus-5
  - claude-sonnet-5
exclude:
  - thinking
  - synthetic
  - timestamps
  - session-markers
  - exchange-markers
  - tool-calls
  - tool-results
  - subagents
---

# alright, im making some changes to reposnapshot's processing configuration. ive created reposnapshot/reposnapshot-v3/processors/configs/*.json to hold the default configurations for processors with keys under that directory. you'll notice alot of rs.*.strip.json files which are foreshadowing other stripping processors for other filetypes, with key pattern denoting the file extension/language they pertain to. the rs-*strip.json files are for current processor ps1 files. the colonel now loads the default configs once at initialization so the processors have access to their default configs, rather than holding default configs in code. but something that's missing is architecturally how do i handle the case of heterogenous repository ingestions where i have a mixture of different file types and i want to be able to toggle comment stripping for any applicable filetype that is configured for stripping. this is an ergonomic consideration that i would want where i could use rs.core.user and pass a -StripComments blanket switch that activates stripping for any allowable filetype in a language specific manner. it also has to respect edge cases like powershell files that could be either ps1 or psm1, but that's secondary to the language routing. its important to work this out now before i begin expanding the language coverage for other types

Read the relevant code. Here's the architecture, and the one structural fact that forces the shape:

## The blocker

The plan is **flat and global**. `Compile-Plan` binds a linear `$Steps` list ([rs.core.colonel.v2.psm1:271](utils/reposnapshot/reposnapshot-v3/rs.core.colonel.v2.psm1:271)), and [chain-executor.ps1:11](utils/reposnapshot/reposnapshot-v3/processors/chain-executor.ps1:11) runs *every step on every item*. Nothing in the plan, the executor, or the processors knows anything about file identity. `-PsStrip` today only works because the docstring tells you to point it at a homogeneous corpus — it will happily run the PowerShell AST stripper over your `.md` files.

So `-StripComments` has no place to land. Something has to acquire a per-item predicate. Three candidate homes:

| Where | Cost |
|---|---|
| **Inside each stripper** (self-gating: check `$Item.Extension`, no-op if not mine) | No colonel change, but chain grows with N strippers × every file, receipts fill with `Skipped: WrongLanguage`, and every processor test must now fake an `Extension`. Kills the ability to deliberately run a stripper on unlabeled content. |
| **A router processor** (one `rs-strip` step dispatching to sub-Fns by extension) | Compile-Plan has to register scripts that aren't steps, and bind sub-configs inside a step's Config. The plan stops being readable as "what runs." |
| **Plan-level predicate** (each bound step carries an optional `When`) | ~3 lines in chain-executor, one field in the bind. Processors stay pure and identity-blind. Recommended. |

## Recommended shape

**1. Gating is a property of the step, not the processor.**

`Compile-Plan` binds `{ Key; Fn; Config; When }` where `When` is `$null` (always runs — today's behavior, unchanged) or a normalized extension set. chain-executor resolves the extension once per item and skips non-matching steps:

```powershell
$ext = Resolve-BagExtension -Item $Item      # '' when the bag has none
foreach ($step in $Plan.Steps) {
    if ($current ... _ChainHalt) { break }
    if ($step.When -and -not $step.When.Contains($ext)) { continue }   # continue, not break
    ...
}
```

`Resolve-BagExtension` goes in `bag-helpers.ps1` alongside `Resolve-BagContent`, same tolerance for string/hashtable/PSCustomObject bags. Resolve it from the *original* descriptor once, not per step — cheaper, and immune to a mutator dropping the field.

The important consequence: **an explicitly-named step is ungated.** `-Processors 'rs-psstrip'` still means "run this on everything," exactly as today. Gates only exist because the blanket expansion attached them. Explicit stays literal; blanket is safe by construction.

**2. The routing key is a language, not an extension** — that's your ps1/psm1 case, and it's data, not code. Each `rs.<lang>.strip.json` self-declares what it claims:

```json
{
  "Language":   "powershell",
  "Extensions": [".ps1", ".psm1", ".psd1"],
  "Processor":  "rs-psstrip",
  "Operations": ["block-comments", "doc-strings", "comment-blocks", "line-comments"],
  "IncludeMeta": true
}
```

Self-declaration over a central `rs.languages.json` registry: adding a language = dropping one file into `configs/`, no second place to forget. The colonel builds the `ext → profile` index in the same init pass that already reads `configs/<key>.json`. **Duplicate extension claims must be a hard error at index build**, not last-writer-wins — you already have `rs.mat.strip.json` and `rs.r.strip.json` sitting next to each other, and `.m` (MATLAB/Obj-C), `.r` (R/Rebol), `.rs` (Rust/RenderScript), `.h` (C/C++/Obj-C) are exactly where that bites.

Build it colonel-side, not processor-side: `Resolve-ProcessorConfig` ([bag-helpers.ps1:110](utils/reposnapshot/reposnapshot-v3/processors/bag-helpers.ps1:110)) leans on `$PSScriptRoot`, which is empty once the body is lifted into the ISS — it only works in the dot-sourced test path. Configs/ layout knowledge has one owner, and it's the colonel.

**3. `-StripComments` is an expansion directive, not a processor.** It resolves the registry into gated steps:

```
file-read
→ rs-psstrip  When {.ps1 .psm1 .psd1}
→ rs-strip    When {.py .pyi}     Config ← rs.py.strip.json
→ rs-strip    When {.ts .tsx}     Config ← rs.ts.strip.json
→ rs-whitespace
→ rs-content_meta
```

Order among strippers is irrelevant (mutually exclusive by extension) — sort by language id so the manifest echo is deterministic.

**Compose it with `-Processors` via a pseudo-key rather than making them exclusive.** `-PsStrip`'s "ignored when -Processors is given" is a dead end here — you'd have no way to say "blanket stripping plus my own indent step." Instead let `'@strip'` appear as a chain entry, intercepted before the `processors\<Key>.ps1` existence check at [rs.core.user.ps1:278](utils/reposnapshot/reposnapshot-v3/rs.core.user.ps1:278):

```powershell
-Processors '@strip', 'rs-indent', 'rs-whitespace', 'rs-content_meta'
```

and `-StripComments` becomes sugar for splicing `@strip` into the default chain. One concept covers both, explicit chains keep positional control, and the sigil makes it unmistakably not a file. (Quote it — bare `@strip` is the splat operator.) It also gives you the obvious place to scope later: `'@strip:powershell,python'`.

**4. The manifest has to record the gates.** `ConfigEcho.Chain` is currently a flat key list ([rs.core.user.ps1:345](utils/reposnapshot/reposnapshot-v3/rs.core.user.ps1:345)). A reading agent looking at a mixed snapshot needs to know *"comments were stripped from .ps1 and .py; this .md is verbatim"* — otherwise it can't tell an uncommented file from a stripped one. Echo the gate map alongside the chain.

## The fork you're actually standing at

Those 11 empty placeholders decide more than naming. `rs.{ext}.strip.json` reads two ways:

- **11 more processor scripts** (`rs-pystrip.ps1`, `rs-tsstrip.ps1`, …), each a near-copy of csstrip with different delimiters; or
- **one generic `rs-strip.ps1` driven by a language profile**, with bespoke scripts only where a real parser is required.

Take the second. Your op vocabulary is *already* language-neutral — `rs-csstrip.json` and `rs-psstrip.json` declare the identical four ops, and csstrip is 90% of a generic stripper already: block / doc / comment-block-run / line / inline are structural classifications, and only the delimiters are language facts. That makes the profile the unit of language coverage, and adding Julia is a JSON file instead of 200 lines of near-duplicate regex.

Three things the profile schema needs beyond delimiters, all of which you'll hit immediately:

- **A doc-comment marker distinct from the line marker** — `///` C#, `//!` Rust, `#'` R roxygen, `--|` Lean. Without it "strip line comments, keep docstrings" is unexpressible outside PowerShell.
- **A `Preserve` list** — the generalization of psstrip's derived-frontmatter promotion (`#Requires`, `#!`). Python coding lines, shebangs on `.sh`/`.nu`, `# pylint: disable`, `//go:build`.
- **A `Nesting` flag** — Rust `/* /* */ */`, Julia `#= =#`, and Lean `/- -/` all nest, which regex cannot do. That flips those languages to a scanner, not a pattern. Worth knowing now, because it means the generic stripper is a small scanner with a profile, not a regex table.

Also flag: csstrip has no string-literal masking (psstrip masks here-strings, [rs-psstrip.ps1:107](utils/reposnapshot/reposnapshot-v3/processors/rs-psstrip.ps1:107)). `$url = "http://x"` in any `//`-language corrupts today. Generalizing the regex path spreads that bug across 11 languages — worth fixing in the generic scanner rather than inheriting.

## Edge cases, resolved

- **Unknown extension → gated step does not run.** Fail-closed. Running an AST stripper on unidentified content is the destructive direction.
- **Case**: lowercase both the index and the resolved extension (`.PS1` exists).
- **Extensionless files** (`Makefile`, shebang scripts): out of scope for v1 — the gate sees only `Extension`. Shebang sniffing needs `Content`, so it'd be a `Detect` clause in the profile evaluated post-`file-read`. Name it, don't build it.
- **`.psd1`**: your call whether it's in the powershell claim. Manifests are often comment-documented and nothing else.
- **`.md` with fenced code**: explicitly out of scope.
- **Growth**: 30 languages = 30 gated steps, each a hashset miss — free. If the plan gets unreadable, gated steps sharing one `Key` (`rs-strip` with different profiles) collapse into a single step carrying a profile-by-extension map. That's the router option arriving later, only for the family that needs it, instead of being designed in up front.

## Code delta

Small, and mostly additive: `Resolve-BagExtension` in bag-helpers; a `When` field in the Compile-Plan bind plus the registry loader beside the existing config read; the skip line in chain-executor; `@strip` interception and `-StripComments` in rs.core.user; gate map in ConfigEcho. The generic `rs-strip.ps1` + profile schema is the real work, and it's separable.

Want me to implement the routing layer first (gating + registry + `@strip`, using `rs-psstrip`/`rs-csstrip` as the only two registered languages), so the plumbing is proven before you start filling in profiles? That's the sequencing I'd pick — it makes the 11 placeholders a data exercise rather than a design exercise.

---

# i was thinking that the plan would intelligently adapt the processor chain to pick the appropriate stripper based on the file extension, and the already-in-place default config can determine the operations unless that's overridden by caller. so instead of high level caller selecting psstrip, the front-end just specifies -StripComments which toggles the internal planning and resolution of type-appropriate stripping processors on a per-ingested-file-bases

Yes — and that's the better primitive. A per-file dispatch table **subsumes** the gating I proposed: a "gated step" is just a table where every entry points at the same Fn. Two mechanisms where one will do — drop `When`, build the table.

## The plan node

`@strip` binds as a step with no single `Fn`, carrying an extension→bind table resolved **once at compile time**:

```powershell
@{ Key = '@strip'
   ByExt = @{
     '.ps1'  = @{ Fn = 'Invoke-RsPsstrip';  Config = @{ Operations = @(...); MaskHereStrings = $true } }
     '.psm1' = @{ Fn = 'Invoke-RsPsstrip';  Config = <same instance> }
     '.py'   = @{ Fn = 'Invoke-RsStrip';    Config = @{ Operations = @(...); Line = '#'; ... } }
   } }
```

Authoring is by language; dispatch is by extension. The ps1/psm1/psd1 case is a build-time flatten — three keys, one bind — so no language concept has to survive into the runspace at all. chain-executor stays nearly dumb:

```powershell
$ext = Resolve-BagExtension -Item $Item          # once, from the original descriptor
foreach ($step in $Plan.Steps) {
    if (halt) { break }
    $fn = $step.Fn; $cfg = $step.Config
    if ($step.ByExt) {
        $bind = $step.ByExt[$ext]
        if (-not $bind) { continue }             # no stripper for this type — pass through
        $fn = $bind.Fn; $cfg = $bind.Config
    }
    $current = & $fn $current $cfg
}
```

Per-item cost is one dictionary lookup, and the init-once property you just built is preserved exactly — every JSON read and merge happens in `Compile-Plan`, none per file.

This also fixes the honesty problem the flat expansion had: `ConfigEcho.Chain` becomes `file-read → @strip{powershell,python,…} → rs-whitespace → rs-content_meta`, which is *true*, instead of listing twenty strippers of which one ran. And the per-file `Processing` audit already records which processor actually fired, so a reading agent can tell stripped-from-uncommented per entry with no new machinery. The `rs-whitespace`/`rs-content_meta` cautions at [rs.core.user.ps1:311](utils/reposnapshot/reposnapshot-v3/rs.core.user.ps1:311) keep working unchanged too, since `@strip` is one key.

## "…unless overridden by caller"

Three layers, merged per language at compile time — a straight generalization of the existing two-layer merge at [rs.core.colonel.v2.psm1:279](utils/reposnapshot/reposnapshot-v3/rs.core.colonel.v2.psm1:279):

```
configs/rs.<lang>.strip.json  →  blanket override  →  per-language override
```

```powershell
@{ Key = '@strip'; Config = @{
     Operations = @('line-comments')                                    # blanket: all languages
     Languages  = @{ powershell = @{ Operations = @('block-comments','line-comments') } }
     Only       = @('powershell','python')                              # optional scoping
} }
```

Bare `-StripComments` passes `Config = @{}` and every language takes its file defaults. That's the whole ergonomic you asked for.

## Two touchpoints that will bite

**`$referencedKeys` ([rs.core.colonel.v2.psm1:165](utils/reposnapshot/reposnapshot-v3/rs.core.colonel.v2.psm1:165))** is derived purely from step keys, and it drives both the bootstrap read and ISS function registration. A dispatch table names processors that are *not* linear steps — if `referencedKeys` doesn't grow to `step keys ∪ table keys`, those Fns are never registered and every dispatch resolves to a command that doesn't exist in the runspace. `$Manifest` is already fine: rs.core.user registers every `processors/*.ps1` regardless of use.

**`$planStepsForWorker` ([rs.core.colonel.v2.psm1:531](utils/reposnapshot/reposnapshot-v3/rs.core.colonel.v2.psm1:531))** rebuilds each step hashtable field-by-field (`Key`/`Fn`/`Config`) when marshalling into the worker pool. A new field is silently dropped there — the serial branch would strip correctly and the parallel branch would strip nothing, with no error anywhere. Marshal `$_` wholesale or add the field explicitly.

## Full delta

| File | Change |
|---|---|
| `bag-helpers.ps1` | `Resolve-BagExtension` — same bag tolerance as `Resolve-BagContent`, `''` when absent |
| `colonel.v2` `Compile-Plan` | scan `configs/rs.*.strip.json`, build ext→bind table, three-layer merge, flatten multi-ext; union into `referencedKeys`; hard error on duplicate extension claims |
| `colonel.v2` `Invoke-Plan` | carry the table across the worker boundary |
| `chain-executor.ps1` | resolve ext once; dispatch or pass through |
| `rs.core.user.ps1` | `-StripComments` → one `@strip` step; intercept `@strip` before the `processors\<Key>.ps1` existence check |
| manifest `ConfigEcho` | record the resolved table, not just the key |

`Invoke-Ingest` needs nothing — it forwards params dynamically.

## Three calls left to you

- **`-PsStrip`'s fate.** Today it's ungated and runs the AST stripper on every file in the corpus. Redefining it as `@strip` scoped to powershell is a behavior change, but only for inputs its own docstring already tells you not to use. Retire it into that, or leave it as-is and just point the docstring at the successor?
- **`@strip` as the key.** The sigil marks "not a `processors\*.ps1` file," which I think is worth keeping — but it has to be quoted in PowerShell (bare `@strip` is the splat operator).
- **`.psd1` in the powershell claim.** Manifests are frequently comment-documented and nothing else.

Say the word and I'll build the routing layer with `rs-psstrip`/`rs-csstrip` as the only two registered languages, so the plumbing is proven before the profiles get filled in.

---

# I will kill -PsStrip, but not until we work out design. a static routing config file containing valid file extension keys that match to specific processors e.g. `"extensions":["ps1","psm1"] , "processors":["rs.ps.strip.ps1"]`type of mapping convention could be used instead and i would have a declarative static default config like the operations settings i've already setup. i mocked an array for "processors" there because i'm anticipating the possibility of more than one language-specific processor per language in a potential chain later

Static routing file works, and the array buys you something structural I'd take further than "later": it makes each route a **plan fragment**, not a mapping. That has consequences worth settling now.

## Shape: key the routes by language, not by rule

```json
{
  "Strip": {
    "powershell": { "Extensions": ["ps1", "psm1"],  "Processors": ["rs-psstrip"] },
    "csharp":     { "Extensions": ["cs", "csx"],    "Processors": ["rs-csstrip"] },
    "python":     { "Extensions": ["py", "pyi"],    "Processors": ["rs.py.strip"] }
  }
}
```

A bare array of `{Extensions, Processors}` rules would work for dispatch, but the language id is what the caller addresses for scoping — `Only = @('powershell','python')`. Without it, scoping has to name extensions individually, which is the exact ergonomic you're eliminating.

Naming the top-level table `Strip` costs one line and leaves room for a second table later. `tp-perplexity` is already a processor that should only see certain files — it's the same dispatch problem wearing different clothes, so `@strip` becomes one instance of a dispatch node rather than a one-off.

**Location:** I'd put it at `processors/routing.json`, sibling to `chain-executor.ps1` and `bag-helpers.ps1` — the other two infra files already excluded from the processor manifest scan. That keeps `configs/` == "exactly one file per processor key, no exceptions," which is a rule you can check mechanically. Putting it in `configs/` means that directory now has two kinds of thing in it. Cosmetic and reversible either way.

## Routing says *who*, configs say *what*

Keep the route entries dispatch-only — no operations, no overrides. Otherwise you get a fourth config layer duplicating `configs/<key>.json`, and two places to look when a run does the wrong thing. Merge stays three layers, addressed by **processor key**:

```
configs/<key>.json  →  blanket override  →  ByProcessor[<key>] override
```

```powershell
@{ Key = '@strip'; Config = @{
     Operations  = @('line-comments')                                 # every stripper
     ByProcessor = @{ 'rs-psstrip' = @{ Operations = @('block-comments','line-comments') } }
     Only        = @('powershell','python')                           # scope by language id
} }
```

Addressing overrides by processor key rather than by language is what keeps the multi-processor array unambiguous — `Languages.powershell.Operations` has no answer when that language's chain has two processors with different config surfaces. Language scopes *which routes participate*; processor key addresses *what each one does*.

## What the array actually changes

**The bind becomes an ordered sub-chain, and declaration order is meaningful.** `ByExt['.ps1']` holds an array of `{Fn; Config}`, and chain-executor loops it — with the halt check re-evaluated *inside* the loop, not just at the outer one. Miss that and a processor that halts mid-sub-chain still gets its successors run:

```powershell
if ($step.ByExt) {
    $binds = $step.ByExt[$ext]
    if (-not $binds) { continue }
    foreach ($b in $binds) {
        if ($current ... _ChainHalt) { break }
        $current = & $b.Fn $current $b.Config
    }
    continue
}
```

Second consequence: the whole-chain cautions in rs.core.user can't see inside a sub-chain. Route `rs-content_meta` into a language chain and the "must be last" caution stays silent. Minor, but it's a blind spot the flat chain didn't have.

**Scope before you union.** `referencedKeys` grows to include every processor named across the routes — so apply `Only`/`Except` *first*, then union, then read and ISS-register. Otherwise a two-language run pays bootstrap-read and per-runspace function registration for all twenty. The same hook later takes the stronger prune: the crawler has already run when ingest is called, so the observed extension set could filter routes down to what's actually in the corpus. Free to add later, needs no design change now — it's another filter on the same table.

## Three things that will silently no-op

- **Extensions normalize on load.** Your mock is dot-less (`"ps1"`); the crawler emits `.ps1` with the dot ([rs.core.crawler.psm1:132](utils/reposnapshot/reposnapshot-v3/rs.core.crawler.psm1:132)). Lowercase and force a leading dot when building the index, or the table never matches anything and nothing errors.
- **Name processor *keys*, not filenames.** `"rs.ps.strip"`, not `"rs.ps.strip.ps1"` — the manifest is keyed by basename-minus-extension ([rs.core.user.ps1:275](utils/reposnapshot/reposnapshot-v3/rs.core.user.ps1:275)). Your placeholder naming already lines up under that: key `rs.ps.strip` → file `rs.ps.strip.ps1` → config `rs.ps.strip.json`. And note what routing buys you here — renaming `rs-psstrip` to `rs.ps.strip` becomes a one-line edit in the routing file plus the file/config rename, with no caller and no chain affected.
- **A malformed routing file must be a hard error.** The existing config load only *warns* on parse failure ([rs.core.colonel.v2.psm1:290](utils/reposnapshot/reposnapshot-v3/rs.core.colonel.v2.psm1:290)) — correct there, since a bad `rs-psstrip.json` degrades to defaults. A bad `routing.json` degrades to "`-StripComments` silently did nothing," which is the worst possible failure for a blanket switch. Same for: unknown processor key, duplicate extension claim across routes, empty `Processors` array.

## One thing routing deliberately doesn't decide

Whether `rs.py.strip` is a bespoke script or a shared generic stripper is a manifest question — routing dereferences a key and doesn't care. So you can settle that per language as you go, and mixing is fine. The only future coupling: if you ever share one generic script across several languages, the route entry needs a per-route `Config`/`Profile` overlay to carry the delimiters, since `configs/<key>.json` would be shared by all of them. Additive when you need it, not now.

## Open calls

1. `processors/routing.json` vs `processors/configs/rs.routing.json`
2. `Strip` as a named table vs routes at the top level
3. `.psd1` in the powershell route
4. `@strip` as the pseudo-key (quoted — bare `@strip` is the splat operator)

---

# i think some of these issues can be alleviated by putting the onus on compiling the chain plan before chain executor sees it

That's the right inversion, and it goes further than alleviating — it takes chain-executor's diff to **zero**.

## The move

`Compile-Plan` stops emitting one plan and emits a **plan family**: N fully-flat, fully-bound step lists, one per route, plus a default. The chain the caller writes is a *template* with `@strip` as a hole; compiling instantiates it once per file class and splices the hole shut:

```
template:    file-read → @strip → rs-whitespace → rs-content_meta

powershell:  file-read → rs-psstrip → rs-whitespace → rs-content_meta
python:      file-read → rs.py.strip → rs-whitespace → rs-content_meta
default:     file-read → rs-whitespace → rs-content_meta          ← hole spliced out
```

Every variant is an ordinary flat chain of `@{Key; Fn; Config}` — the exact shape chain-executor already consumes. It never learns what an extension is.

## What that deletes

- **The nested halt check.** No sub-chain exists; a language's two processors are peers in a flat list, so the existing halt-at-top-of-loop is correct again.
- **The multi-processor array as a special case.** `"Processors": ["rs.ps.strip","rs.ps.dedoc"]` is a compile-time splice of two steps. Declaration order is preserved by construction — no new bind shape, no ordered-array semantics to document at runtime.
- **`Resolve-BagExtension`.** Extension resolution happens colonel-side where `$Item.Extension` sits on the descriptor and there's no ISS boundary to cross. bag-helpers is untouched.
- **The caution blind spot** — and it inverts into coverage. "content_meta must be last," "chain omits rs-whitespace" now run per compiled variant, which is strictly more than today's single check. `Only`-scoping and corpus-pruning are filters on the route table before compilation, so they cost nothing.
- **`ConfigEcho` honesty**, again improved: echo the variant chains verbatim. A reading agent gets `powershell: file-read → rs-psstrip → …` / `default: file-read → …`, which is literally what ran per file class.

One correction to what I said earlier: there's no separate serial branch — [colonel.v2:531](utils/reposnapshot/reposnapshot-v3/rs.core.colonel.v2.psm1:531) is the single marshalling point, so the risk there was a silent field-drop, not a serial/parallel divergence. Under this design it mostly evaporates anyway, since the step shape stays `@{Key;Fn;Config}` and it's the *plan argument* that changes — a visible signature change that fails loudly.

## Where routing lands

Slice time, as a third parallel array alongside the two that exist. Slicing is round-robin at [colonel.v2:445](utils/reposnapshot/reposnapshot-v3/rs.core.colonel.v2.psm1:445) with `$OrderedOut[$idx]` preserving order, so it's symmetric:

```powershell
$sliceItems[$slot].Add($Items[$i])
$sliceIdxs[$slot].Add($i)
$slicePlans[$slot].Add($extToVariant[$ext] ?? 'default')    # variant id, resolved here
```

The worker then does `$plan = $Family[$MyPlanKeys[$i]]` — an index lookup, no extension logic, no conditionals. The colonel decides; the worker obeys. That's the full expression of putting the onus on compilation.

Variant identity should be per *route*, not per extension — `.ps1` and `.psm1` share one compiled list, so 20 languages is 21 variants, each compiled once with shared config object references. Marshal the family as plain nested hashtables, keeping the deliberate minimal-shape discipline that's already at :531.

## The one thing this forecloses

Routing is chosen before `file-read` runs, so it can never depend on **content** — no shebang sniffing for extensionless files (`Makefile`, `#!/usr/bin/env nu` with no extension). Extension-only routing was already the v1 call, so nothing is lost today, but it's now structural rather than incidental.

The escape hatch, if you ever want it: hoist `file-read` out of the variants into a fixed prologue, and route on the post-read bag. That makes it a two-wave dispatch in `Invoke-Plan` rather than one, which is a real restructure — worth knowing the shape exists, not worth building for it now. It doesn't change any decision in front of you.

## What's actually left to decide

The routing file's own questions survive unchanged — `processors/routing.json` vs `configs/`, `Strip` as a named table, `.psd1`, dot-normalization on load, hard-error-on-malformed. Those are about the *file*, not the mechanism.

The mechanism adds one: **does `@strip` splice to nothing in the default variant, or does an unrouted file get no chain at all?** Splicing to nothing is right — a `.md` file should still get `file-read → rs-whitespace → rs-content_meta`; it just isn't stripped. But that means the default variant always exists and is the template minus every hole, which is worth stating as an invariant rather than falling out by accident.

---

# an unrouted file doesn't get any routed treatment. no stripper or otherwise filetype specific -> doesn't get stripped or otherwise, but everything else in the same order

Settled, and it closes into a general rule rather than a special case for stripping:

**A template is a flat chain that may contain holes. Compiling instantiates it per route: each hole is replaced by that route's processors in declared order; the default variant is the template with every hole removed. Non-hole steps keep their relative order in every variant.**

Which gives you, for free:

- **Position is the caller's.** `-Processors 'rs-indent','@strip','rs-whitespace'` strips after indent. The hole isn't pinned to a slot in the pipeline — it's wherever it's written. `-StripComments` is then just "the template contains `@strip`," inserted after `file-read` if the caller didn't place it themselves, and a no-op if they did. No exclusivity rule against `-Processors` needed.
- **More than one hole works with no new machinery.** When `tp-perplexity` or a future `@parse` wants routed treatment, it's a second table in the routing file and a second hole in the template. Each splices independently; the default variant drops both.
- **Variants differ in length, so nothing may key on step index.** No code does today, but the manifest echo is the obvious future temptation — key it by variant.

One collision worth a caution rather than an error: a route naming a processor the template already lists explicitly compiles it twice in that variant. Harmless for idempotent ops, silently doubled work otherwise.

That's the mechanism fully closed. What's left is all file-level, and my recommendation on each:

| | Recommend |
|---|---|
| Location | `processors/routing.json` — keeps `configs/` at exactly one file per processor key, mechanically checkable |
| Top-level | Named table (`"Strip": {...}`) — one line now, room for `"Parse"` later |
| Route keys | Language ids, extensions dot-less in the file, normalized to lowercase-with-dot on load |
| `Processors` entries | Processor **keys**, not filenames (`"rs-psstrip"`, later `"rs.ps.strip"`) |
| `.psd1` | Include it — you can drop it from one array later if manifest comments turn out to matter |
| Malformed routing file | Hard error, unlike `configs/<key>.json`'s warn-and-default |

Want me to write this up as `docs/routing-and-templates.md` first so the target shape is on paper before code, or go straight to implementing the compile-time split with `rs-psstrip`/`rs-csstrip` as the only two routes?

---

# well, there are declared stages, with order determined canonically internally based on mutation / not mutation, but ordering even within mutation. stripping has a place. some other type specific might sit somewhere else, in theory. each language-typed case gets a $meta-token assigned to its place ($strip, $whatever, $whatever else). They get declared in the order, and cases that don't resolve under a $meta-token have that $step removed from their chain

Then the canon replaces caller positioning entirely, and it's worth naming *why* each edge exists — because that's what makes the next token's placement derivable instead of a judgment call:

**Stage A must follow stage B if B can produce output violating A's postcondition.**

Every edge you have falls out of that. Stripping emits trailing whitespace and blank runs → violates whitespace-tidy's postcondition → tidy runs after strip. Every mutator invalidates a measurement → measure runs last. Indent's common-indent calculation changes once standalone comment lines are gone → indent runs after strip. None of that is taste, and when `$whatever-else` shows up you place it by asking which existing postconditions it can break, not by arguing about pipelines.

There's live evidence the canon exists but isn't enforced: [rs-csstrip.ps1:31](utils/reposnapshot/reposnapshot-v3/processors/rs-csstrip.ps1:31), [rs-whitespace.ps1:35](utils/reposnapshot/reposnapshot-v3/processors/rs-whitespace.ps1:35), and [tp-perplexity.ps1:48](utils/reposnapshot/reposnapshot-v3/processors/tp-perplexity.ps1:48) each defensively re-normalize line endings, because no one can currently rely on running after a stage that guarantees it. Once the spine is declared, that's either deletable or a sign that line-ending canonicalization is its own early stage rather than an op inside whitespace-tidy.

## The spine is an artifact, not a caller argument

```json
{
  "Stages": [
    { "Stage": "read",       "Processor": "file-read" },
    { "Stage": "$parse",     "Routed": "Parse" },
    { "Stage": "$strip",     "Routed": "Strip" },
    { "Stage": "indent",     "Processor": "rs-indent" },
    { "Stage": "whitespace", "Processor": "rs-whitespace" },
    { "Stage": "measure",    "Processor": "rs-content_meta" }
  ],
  "Strip": {
    "powershell": { "Extensions": ["ps1","psm1","psd1"], "Processors": ["rs-psstrip"] },
    "csharp":     { "Extensions": ["cs","csx"],          "Processors": ["rs-csstrip"] }
  }
}
```

Spine and routing tables belong in the same file: token ids have to agree across them, and splitting them means a rename can silently orphan a stage.

Callers then **enable stages, never order them**. `-StripComments` turns on `$strip`. Compilation walks the spine once per file class, keeps enabled stages, resolves routed ones, drops tokens that don't resolve for that class.

## The fork this forces

`-Processors` as an ordered caller-supplied chain and a canonical spine can't both be authoritative. Either it becomes a **set** — the caller names participants, the compiler orders them, and array position is meaningless (or a validation error when it contradicts canon) — or it stays a literal sequence that bypasses the spine.

I'd take both, explicitly separated: `-Processors` becomes a set under the canon, and a distinct flag means "take my order verbatim, cautions only." That keeps reposnapshot usable as an instrument for deliberately violating its own invariants, which you will want, without letting a plain call do it by accident. Name that flag carefully — `-OrderStrict` is already taken by bin packing at [rs.core.user.ps1:97](utils/reposnapshot/reposnapshot-v3/rs.core.user.ps1:97).

That also cleanly disposes of the three soft cautions at [rs.core.user.ps1:311](utils/reposnapshot/reposnapshot-v3/rs.core.user.ps1:311): under the canon they become compiler guarantees and stop being printed at all; under the verbatim flag they're exactly the right warnings and stay.

## Two consequences of having more than one token

**Variant identity is the tuple of resolutions, not one token's.** A `.md` file might resolve `$parse` and not `$strip`; a `.ps1` the reverse. Variants key on the whole tuple — bounded by the tuples actually present in the corpus, not the product of the tables, but it's the thing that surprises you when the second token lands.

**Tokens are the unit of echo.** In the manifest, `$strip → rs-psstrip` reads differently from a fixed stage, and that distinction is what tells a reading agent "this position was type-routed, and for this file it resolved to nothing" versus "this stage doesn't exist in this run."

One practical note on the sigil: `'$strip'` is literal in single quotes and in JSON, but `"$strip"` in PowerShell double quotes interpolates to an empty string. Silent, and exactly the kind of thing that shows up as a mysterious missing stage.

Ready to write this up as the design doc — spine, derivation rule, routing tables, compilation, variant tuples — or do you want to settle the `-Processors` set-vs-sequence call first, since it changes what the doc says about the caller surface?

---

# <command-name>/model</command-name>
            <command-message>model</command-message>
            <command-args>claude-sonnet-5</command-args>

---

# <local-command-stdout>Set model to claude-sonnet-5</local-command-stdout>

No response requested.

---

# <command-message>chat-export</command-message>
<command-name>/chat-export</command-name>
<command-args>`D:\aghado01\science-facility\issues\reposnapshot\discussions`</command-args>
