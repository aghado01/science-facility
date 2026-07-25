# Brief: session-id resolver for the chat exporter

**Status:** OPEN — code update first. Skill minting is explicitly OUT of scope (see §7).
**Target repo:** `D:\aghado01\utils\jso-jackson\claude-export\` (the utils copy — see §2)
**Authored:** 2026-07-24, from the design discussion in session `296be375-492a-464f-a08e-55cc1bf962f8`
(exported to `D:\aghado01\.discussion\opus-296be375-492a-464f-a08e-55cc1bf962f8.md`).

---

## 1. Objective

`Invoke-ClaudeThreadExport` currently requires the caller to supply BOTH `-SourceDir` (the
project transcript folder) and `-SessionIds`. The session id alone is sufficient: the transcript
path is structurally guaranteed to be

```
{claudeConfigRoot}/projects/{encodedProjectDir}/{sessionId}.jsonl
```

Add a resolver so that **given only a session id, the tool locates its own transcript**. This
removes the caller's need to know the project-dir encoding, and makes the forthcoming
`chat-export` skill a thin, branch-free wrapper.

## 2. Which copy to edit (IMPORTANT)

Two divergent copies of jso-jackson exist. **Edit the utils one. Do not touch `.claude/tools`.**

| | `C:\Users\azrie\.claude\tools\jso-jackson` | `D:\aghado01\utils\jso-jackson` |
|---|---|---|
| status | **RETIRING** — do not modify | **CANONICAL** — edit here |
| `claude-jso-*.ps1` mtime | 2026-05-16 (units: 2026-04-26) | 2026-07-23 |
| layout | flat | primitives at root, exporter under `claude-export/` |
| divergence | all 7 shared `.ps1` files differ by SHA-256 | utils is newer by ~2 months |

Rationale: the user is centralizing agentic tooling under `D:\aghado01\utils` so the
jso-jackson primitives (`jso-jackson.ps1`, `jso-debug.ps1`, `jso-hash.ps1`) can be reused across
tools rather than living inside `.claude`.

**Caveat for the implementer:** the export run verified on 2026-07-24 used the OLDER `.claude`
copy. The utils copy is newer but was not exercised. **Before making changes, confirm the utils
copy runs a baseline export successfully** — otherwise a failure after the edit is ambiguous
between "my resolver broke it" and "the utils copy was already divergent/broken."

## 3. Verified facts (established 2026-07-24 — do not re-derive)

1. **The harness exposes the session id to the agent**: `$env:CLAUDE_CODE_SESSION_ID`
   = `296be375-492a-464f-a08e-55cc1bf962f8`, which matched the transcript filename exactly.
   (This was NOT true when the exporter was first written; it is true now.)
2. **Decoys**: `CLAUDE_CODE_HOST_SESSION_ID` (`local_c6588df0-…`) and `CLAUDE_CODE_CHILD_SESSION=1`
   also exist and are **not** the transcript key. Only `CLAUDE_CODE_SESSION_ID` matches.
3. **Session ids are globally unique across projects**: 14 project dirs, 222 `.jsonl` files,
   **zero** duplicate UUID basenames. The id alone is a sufficient key.
4. **Project-dir encoding** is cwd with `[:\\/ ]` → `-`
   (`D:\aghado01\codex-scientiae` → `D--aghado01-codex-scientiae`), but see §4: we deliberately
   do NOT depend on this.
5. **Nested strays exist**: 11 non-UUID `.jsonl` files live below project dirs. A one-level
   lookup excludes them by construction; never use `-Recurse`.
6. **`$env:CLAUDE_CONFIG_DIR` was EMPTY** in a live agent shell on 2026-07-24 — the original
   scratch template's `. "$env:CLAUDE_CONFIG_DIR/tools/..."` dot-source failed because of it.
   The resolver must not assume it is set.

## 4. Design decisions (settled — implement, do not relitigate)

**D1. Glob/probe by session id; do NOT derive the project dir from cwd.**
Deriving re-implements an undocumented Claude Code convention that could drift (dots, UNC,
unicode). Probing by UUID is exact, filename-only, and additionally correct when exporting a
thread from a different cwd than the one it ran in.

**D2. Fail loud; NO fallbacks.**
If the session id is unavailable, or resolution yields 0 or >1 hits, **throw**. Do not fall back
to newest-mtime, and do not content-search transcripts. Rationale (user, verbatim intent): a
missing session id is "a highly unexpected case and my concerns would immediately elevate to a
system problem of unknown origin" — a silent fallback converts a loud system fault into a quiet
wrong-thread export. Newest-mtime is also unsafe under concurrent sessions, which this user runs.

**D3. Do NOT lift the reposnapshot crawler**
(`D:\aghado01\utils\reposnapshot\reposnapshot-v3\rs.core.crawler.psm1`). It was evaluated and
rejected on evidence, not taste:

| approach | time | work done |
|---|---|---|
| direct probe/glob | 94 ms | exactly the match |
| crawler BFS | 267 ms | 70 dirs, 550 files, a `SizeBytes` stat on every one |

2.8× slower today and O(tree) vs O(one lookup) — the gap widens as history grows. The crawler's
real value (per-directory failure domains, reparse-point skipping, `Skipped` diagnostics) is for
unknown/hostile trees; `~/.claude/projects` is machine-generated, flat, and known
(`SkippedCount=0`). Lifting it would also mean either copying a 227-line class (which then
drifts) or taking a dependency the user explicitly does not want yet.

**D4. Keep `-SourceDir` load-bearing for the batch/chain paths.**
`Get-ClaudeThreadPlan` and `Invoke-ClaudeThreadExportBatch` genuinely enumerate a directory.
This is a resolver added *in front of* the single-thread entry point, not a module-wide
signature change.

## 5. Implementation spec

### 5a. New function `Resolve-ClaudeThreadPath`

In `claude-export/claude-jso-run.ps1`.

```powershell
param(
    [Parameter(Mandatory)][string]$SessionId,
    [string]$ConfigRoot   # optional override
)
```

- **Root resolution:** `$ConfigRoot` → else `$env:CLAUDE_CONFIG_DIR` (if non-empty) → else
  `Join-Path $env:USERPROFILE '.claude'`. Throw if `{root}/projects` does not exist.
- **Validate** `$SessionId` against `^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$` (ordinal,
  case-insensitive); throw on malformed input rather than probing for it.
- **Probe** — explicit .NET, per the user's low-level PowerShell preference (no pipeline idioms,
  no `Get-ChildItem` globbing engine, no `FileInfo` allocation):

```powershell
$hits = [List[string]]::new()
foreach ($d in [Directory]::EnumerateDirectories($projectsRoot)) {
    $p = [Path]::Combine($d, "$SessionId.jsonl")
    if ([File]::Exists($p)) { $hits.Add($p) }
}
```

- **Guards (fail loud):**
  - `0` hits → `throw "No transcript found for session {id} under {projectsRoot}"`
  - `>1` hits → `throw` listing every path found. Empirically impossible today (§3.3); the guard
    costs one line and surfaces exactly the anomaly class D2 wants screaming.
- **Return** `[PSCustomObject]` with `SessionId`, `JsonlPath`, `SourceDir` (containing project
  dir), `ProjectName` (leaf), `ConfigRoot`.

### 5b. `-SessionId` parameter set on `Invoke-ClaudeThreadExport`

- Add parameter sets: `BySessionId` (new) and `BySourceDir` (existing behaviour, default).
- Under `BySessionId`: call the resolver, then populate the existing internals with
  `SourceDir = $resolved.SourceDir` and `SessionIds = @($SessionId)`.
- **No changes downstream.** The chain-walk in `New-ClaudeThreadManifest -SessionIds` operates
  within `SourceDir`, which the resolver supplies correctly.
- Existing `-SourceDir` callers must remain byte-for-byte compatible.

## 6. Verification

Run **from the utils copy** (`D:\aghado01\utils\jso-jackson\claude-export\claude-jso-run.ps1`):

1. **Baseline first** (see §2 caveat) — old-style call with explicit `-SourceDir` + `-SessionIds`
   for session `296be375-492a-464f-a08e-55cc1bf962f8`; confirm it produces markdown.
2. **Equivalence** — same session via `-SessionId` only. Assert the output markdown is
   **identical** to the baseline. This isolates resolver correctness from the utils/`.claude`
   code divergence.
3. **Guard tests** — a well-formed but nonexistent UUID → throws "no transcript"; a malformed id
   → throws on validation; `$env:CLAUDE_CONFIG_DIR` unset → still resolves via `$env:USERPROFILE`.
4. Known-good reference output from the `.claude` copy on 2026-07-24:
   `D:\aghado01\.discussion\opus-296be375-492a-464f-a08e-55cc1bf962f8.md`
   (9 exchanges; 180 source records → 101 after filter → 40 deduped → 61 merged).
   Treat as a sanity reference only — the utils code has diverged, so exact-match is NOT expected
   across copies (only within step 2).

### Reference invocation (current settings)

```powershell
$exclude = @('thinking','synthetic','timestamps','session-markers',
             'exchange-markers','tool-calls','tool-results','subagents')
Invoke-ClaudeThreadExport -SessionId $env:CLAUDE_CODE_SESSION_ID `
    -MarkdownDir 'D:\aghado01\.discussion' `
    -Exclude $exclude -Format 'Structural' -OutputPrefix 'opus'
```

## 7. OUT OF SCOPE — deferred to discussion after the code lands

Do **not** implement these; the user wants to discuss them first.

- **Minting the `chat-export` skill.** Design context so far: the skill becomes ~4 lines with no
  branching — read `$env:CLAUDE_CODE_SESSION_ID`, throw if empty, call the tool, report the
  output path. Anti-flood doctrine to encode when it IS written: resolve to a *filename*, never
  read transcript content into context; if content search is ever needed, filenames-only mode
  (`Select-String -List` / `rg -l`) and scope to one project dir. Home per user convention:
  `~/.claude/skills/chat-export/SKILL.md` — but note the tension with centralizing tools under
  `D:\aghado01\utils`, which is itself a discussion item.
- **Retiring `.claude/tools/jso-jackson`** — sequencing, and what else references it.
- **Reuse of the jso-jackson primitives** across other agentic tools (the motivation for
  centralizing).
- **`-MarkdownDir` default** of `D:\aghado01\.discussion` — currently passed per-call.

## 8. Completion report

**Completed 2026-07-25.** Implemented as specified in §5. Skill minting and `.claude/tools`
retirement (§7) untouched.

### 8a. What changed

Single file: `D:\aghado01\utils\jso-jackson\claude-export\claude-jso-run.ps1`.

1. **New `Resolve-ClaudeThreadPath -SessionId [-ConfigRoot]`** (placed after the dot-sources,
   ahead of `Invoke-ClaudeThreadExport`). Exactly per §5a:
   - Root: `-ConfigRoot` → `$env:CLAUDE_CONFIG_DIR` (non-empty test, not existence test) →
     `{USERPROFILE}\.claude`. Throws if all three are unavailable, and throws if
     `{root}/projects` does not exist.
   - Validates `^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$` via
     `[Regex]::IsMatch` with `IgnoreCase -bor CultureInvariant` **before** touching the
     filesystem.
   - Probes with `[Directory]::EnumerateDirectories` + `[Path]::Combine` + `[File]::Exists`
     into a `List[string]`. One level, no `Get-ChildItem`, no `-Recurse`, no `FileInfo`
     allocation.
   - Guards: 0 hits → throw; >1 hits → throw listing every path.
   - Returns `SessionId`, `JsonlPath`, `SourceDir`, `ProjectName`, `ConfigRoot`.
2. **`-SessionId` parameter set on `Invoke-ClaudeThreadExport`.** `[CmdletBinding(DefaultParameterSetName='BySourceDir')]`;
   `SourceDir`/`SessionIds` are pinned to `BySourceDir`, new `SessionId`/`ConfigRoot` to
   `BySessionId`. Every other parameter is left unattributed so it belongs to both sets. Under
   `BySessionId` the body calls the resolver and assigns `$SourceDir = $resolved.SourceDir`,
   `$SessionIds = @($SessionId)` before any existing logic runs — no downstream code changed.
3. **Header comment block** — added the resolver to the FUNCTIONS list plus a
   `SESSION-ID ENTRY POINT` section recording the fail-loud rationale (D2), so the
   no-fallback decision is defended at the code, not just in this brief.

### 8b. Verification results (§6)

All runs from the utils copy, artifacts in a session scratchpad (not `.discussion`).

| # | Test | Result |
|---|---|---|
| 1 | **Baseline** — `-SourceDir` + `-SessionIds` for `296be375-…`, pre-edit | PASS — 30,997-byte markdown, 219→114→43→71, 14 exchanges |
| 2 | **Equivalence** — same session, `-SessionId` only | PASS — byte-identical except one line |
| 3a | Well-formed nonexistent UUID (`00000000-…`) | throws `No transcript found for session … under …\projects` |
| 3b | Malformed (`not-a-uuid`, trailing `Z`, `../../etc/passwd`) | all throw on validation, before any FS access |
| 3c | `$env:CLAUDE_CONFIG_DIR` empty string / unset / set | all three resolve to `C:\Users\azrie\.claude` |
| 3d | Bad `-ConfigRoot` | throws `Claude projects root not found: …` |
| 3e | Uppercase UUID | resolves (case-insensitive as specified) |
| 3f | `-SessionId` and `-SourceDir` together | PowerShell rejects: parameter set cannot be resolved |
| 3g | `-SessionId` bad id via `Invoke-ClaudeThreadExport` | throws through the wrapper |
| 4 | **Regression** — `Get-ClaudeThreadPlan` on the 106-file dir | 106 chains / 106 leaves, unchanged |
| 5 | **Regression** — `Invoke-ClaudeThreadExportBatch` full run | 3 threads, 3 markdown files, unchanged |

**On step 2's "identical":** the two markdowns differ on exactly one line —
`exported_at: 2026-07-25T03:58:07.87…Z` vs `…T03:59:31.77…Z`, the frontmatter stamp, which is
regenerated per run and cannot match across two invocations. All 266 other lines are `-cne`-clean
and both files are 30,997 bytes. Resolver correctness is established.

Incidental confirmation of **D1**: cwd during the test was `D:\aghado01\utils\jso-jackson`, and the
session resolved into `D--aghado01-codex-scientiae`. A cwd-derived project dir would have missed it.

### 8c. Findings against §2–§4

**§3.6 holds and is worse than stated — this is the one thing to carry into the §7 discussion.**
`$env:CLAUDE_CONFIG_DIR` was again empty in this agent shell. The resolver handles it, but two
*pre-existing* call sites build paths from it with no fallback:

- `jso-jackson.ps1:2416` — `New-JobWorkingDir`: `[Path]::Combine($env:CLAUDE_CONFIG_DIR, 'tmp')`
- `claude-jso-run.ps1` — `Invoke-ClaudeThreadExportBatch` `WorkingDir` and `MarkdownDir` defaults

`[Path]::Combine('', 'tmp')` returns the **relative** string `tmp`, so with the variable empty the
default working dir is created under whatever the current directory happens to be, not
`~/.claude/tmp`. §6's reference invocation omits `-WorkingDir`, so the deferred `chat-export`
skill would, as drafted, scatter `tmp/claude-jso-run/{ts}/` into whichever repo is cwd when the
user invokes it. **Not fixed here** — it lives in a different file, predates this work, and
changing it silently relocates the default output of every existing caller. It should be settled
alongside the `-MarkdownDir` default already listed in §7.

**§6.4's reference numbers are stale, not contradicted.** The known-good line (180→101→40→61,
9 exchanges) does not reproduce; the utils copy yields 219→114→43→71 and 14 exchanges. The
source transcript grew from 180 to 219 records because session `296be375-…` continued after the
2026-07-24 export, so copy divergence and transcript growth are confounded and cannot be
separated from this number alone. §6.4 already scoped itself to "sanity reference only", and
step 2's within-copy equivalence is the test that actually matters. Worth restamping the
reference if it is kept.

**§2's caveat was worth having, and discharged.** The utils copy ran the baseline clean on first
attempt — no latent breakage, so the equivalence result is unambiguous.

**Minor, no action:** the projects root now holds 16 project dirs (4 of them empty of top-level
`.jsonl`) against §3.3's 14. Consistent with normal growth; §3.3's uniqueness conclusion was not
re-derived, per instruction.

---

## 9. Follow-up: removing the `CLAUDE_CONFIG_DIR` dependency

**Completed 2026-07-25**, on the user's instruction to refactor so the code works without
depending on `$env:CLAUDE_CONFIG_DIR` *and* without hard-coding a filesystem path. This closes
the §8c finding.

### 9a. What the audit found

Four sites read the empty variable, and they were conflating **two different roots**:

| # | Site | Root wanted | Symptom with the var empty |
|---|---|---|---|
| 1 | `jso-jackson.ps1` — `New-JobWorkingDir` default `$Root` | write: `{root}/tmp` | `Combine('','tmp')` → relative `tmp` under cwd |
| 2 | `claude-jso-run.ps1` — batch `WorkingDir` default | write: `{root}/tmp` | same |
| 3 | `claude-jso-run.ps1` — batch `MarkdownDir` default | write: `{root}/tmp` | same |
| 4 | `claude-jso-jackson.ps1` — `Get-ClaudeCurrentSessionFile -ProjectsRoot` default | read: `{root}/projects` | resolved to relative `projects`, then threw |

The **read** root is not ours to choose — it is wherever Claude Code writes transcripts, and must
be *discovered*. The **write** root only needs a real, absolute base directory. Collapsing both
onto one env var is why a single empty string broke all four.

Dependency graph (established, not assumed):
`claude-jso-run.ps1` → `claude-jso-jackson.ps1` → `../jso-jackson.ps1`. The base layer already
carried the Claude coupling (site 1), so that is where discovery belongs — one function knows
Claude's layout, four sites consume it.

### 9b. What was added — `jso-jackson.ps1`, new `Claude Config Root` region

- **`Get-ClaudeConfigRootCandidate`** — builds conventional locations at call time from
  `[Environment]::GetFolderPath('UserProfile')` (the OS API, with `USERPROFILE`/`HOME` as
  backstops), plus `XDG_CONFIG_HOME`. Returns `{home}/.claude`, `{XDG}/claude`,
  `{home}/.config/claude`, separator-normalized via `GetFullPath`.

  *This is the crux of "no hard-coded path".* The list contains no absolute path literal — only
  directory **names** that are Claude Code's own storage convention, joined onto a home the
  operating system reports. `C:\Users\azrie\.claude` is a hard-coded path; `.claude` under the
  OS-reported home is a convention, identical on every machine and account.

- **`Get-ClaudeConfigRoot [-ConfigRoot] [-RequireProjects]`** — resolution in strict order:
  1. `-ConfigRoot` (explicit caller override)
  2. `$env:CLAUDE_CONFIG_DIR` — **honoured when set, never required**
  3. probed candidates

  Sources 1 and 2 are authoritative: a supplied-but-invalid root **throws** rather than falling
  through to a probe, because silently ignoring an explicit root would hide the exact
  misconfiguration the caller was trying to state. This is D2's fail-loud doctrine applied to
  configuration. Every candidate must prove itself on disk before being returned — under
  `-RequireProjects`, by actually containing `projects/`. A guess that cannot be corroborated is
  rejected, never returned.

  `-RequireProjects` is what separates the two roots: read paths demand a root that really holds
  transcripts and throw otherwise; write paths accept the conventional location so a first run on
  a fresh machine still creates an absolute, predictable directory.

- **`Get-ClaudeProjectsRoot [-ConfigRoot]`** — `{discoveredRoot}/projects`, required to exist.

**Not added:** no result caching (the probe is a few `Directory.Exists` calls; staleness would
cost more than it saves) and no module-global `Set-ClaudeConfigRoot`. Every call site already has
an explicit override parameter — `-ConfigRoot`, `-Root`, `-WorkingDir`, `-MarkdownDir`,
`-ProjectsRoot` — so a fourth injection channel would add hidden order-dependent state for
nothing.

### 9c. Call sites rewired

1. `New-JobWorkingDir` → `Combine((Get-ClaudeConfigRoot), 'tmp')`
2. batch `WorkingDir` → `Combine((Get-ClaudeConfigRoot), 'tmp', $slug, $stamp)`
3. batch `MarkdownDir` → `Combine((Get-ClaudeConfigRoot), 'tmp', 'markdown')`
4. `Get-ClaudeCurrentSessionFile` → `$ProjectsRoot` default moved out of the param block into the
   body (`if (-not $ProjectsRoot) { $ProjectsRoot = Get-ClaudeProjectsRoot }`) so a discovery
   failure surfaces as its own error instead of parameter-binding noise
5. `Resolve-ClaudeThreadPath` → its bespoke root logic from §8a replaced by
   `Get-ClaudeConfigRoot -RequireProjects` + `Get-ClaudeProjectsRoot`

Doc comments claiming `~/.claude/tmp/...` were restated as `{configRoot}/tmp/...`.

**Exactly one live read of `$env:CLAUDE_CONFIG_DIR` remains in the whole tree** — the
authoritative-source branch inside `Get-ClaudeConfigRoot`. The other eight occurrences are
docstrings, comments, and one error-message string.

### 9d. Verification

Parse check: 0 errors across all three edited files.

| Test | Result |
|---|---|
| `CLAUDE_CONFIG_DIR` empty / unset / whitespace | all resolve to `C:\Users\azrie\.claude` |
| set and valid | honoured (returned verbatim) |
| set but nonexistent | **throws**, does not fall through to probe |
| set, exists, but no `projects/` | passes bare, **throws** under `-RequireProjects` |
| `-ConfigRoot` bogus, with a *valid* env var present | **throws** — explicit input wins and is not rescued |
| **`New-JobWorkingDir` with no `-Root`, cwd = repo root** | `C:\Users\azrie\.claude\tmp\…` — rooted, **no `./tmp` in cwd** |
| **batch with no `-WorkingDir`/`-MarkdownDir`** | `~/.claude/tmp/{slug}/{stamp}` and `~/.claude/tmp/markdown` |
| `Get-ClaudeCurrentSessionFile`, default root, env empty | found this session's own transcript |
| … explicit root / bad root / no history | matches / throws / returns `$null` as documented |
| Resolver guards from §8b (malformed, nonexistent, explicit root, bad root) | unchanged |
| `Get-ClaudeThreadPlan` on the 106-file dir | 106 chains, unchanged |
| **End-to-end `-SessionId` with no `-WorkingDir`** (the skill invocation shape) | markdown byte-identical to the §8b baseline — 30,997 bytes, 267 lines, sole diff the `exported_at` stamp |

Corroboration that `~/.claude/tmp` was always the intended target, not a new invention:
`~/.claude/tmp/` already contained a `claude-jso-run/` directory (2026-07-23) and `markdown/`
(2026-05-25) from earlier runs made when the variable *was* populated. The fix restores the
documented behaviour rather than relocating anything. All test artifacts created under
`~/.claude/tmp` during verification were removed; pre-existing directories were left intact.

### 9e. Discovered, not fixed

**Timestamp-format inconsistency between the two working-dir defaults.**
`New-JobWorkingDir` stamps with `[datetime]::UtcNow`, while the batch default in
`Invoke-ClaudeThreadExportBatch` uses `[DateTime]::Now` (local). Observed side by side during
verification: `claude-jso-run\20260725_040957` (UTC) beside
`D--aghado01-utils-reposnapshot\20260724_211043` (local, same moment). Sibling run directories
under the same `tmp/` root therefore sort inconsistently and can appear to be from different
days. Pre-existing, unrelated to `CLAUDE_CONFIG_DIR`, and a one-word fix — but it changes
directory names, so it is left for the §7 discussion alongside the `-MarkdownDir` default.
