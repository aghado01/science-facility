# RepoSnapshot V3 Processor Architecture & Standards

This directory contains the step processors, execution engine, shared helper libraries, externalized configurations, and documentation for RepoSnapshot V3's ingestion stage.

---

## 1. Core Invariants

All processors in this directory must strictly comply with the following architectural invariants:

### Runspace Boundary
- **Runspace-Isolated Execution**: Processors execute exclusively inside isolated PowerShell `Runspace` instances managed by Colonel (`rs.core.colonel.v2.psm1`).
- **Dual Execution Topology**: The same processor scripts execute in both:
  - *Serial Branch*: A single dedicated runspace instantiated from Colonel's `InitialSessionState` (ISS).
  - *Parallel Branch*: Multi-threaded worker pools where each worker runspace is built from the same ISS.

### ISS-Load Safety
- **No `#Requires` Directives**: Scripts must not contain `#Requires -Version` or `#Requires -Modules` statements, as they interfere with dynamic AST compilation and ISS entry creation.
- **No `Set-StrictMode`**: Script bodies must avoid global strict-mode switches that alter ambient runspace semantics.
- **Top-Level `param(...)` Contract**: Every processor must expose a top-level parameter block as its sole entry surface:
  ```powershell
  param(
      [Parameter(Position = 0)]
      [object]$Item,

      [Parameter(Position = 1)]
      [hashtable]$Config = @{}
  )
  ```

### Closure Rule (Pure Functions)
- **Zero Ambient State**: Processors must be pure functions with no module-scope or script-scope variable dependencies (`$script:`, `$global:`).
- **Runspace Isolation**: The closure environment does not cross the runspace boundary. All required runtime state, options, and helpers must arrive via parameters or registered ISS function entries.

---

## 2. Harmonized Mutator Contract (6d)

All content-transforming processors adhere to the harmonized 6d mutator contract:

### Content-Key Resolution (`Resolve-BagContent`)
- Processors accept heterogeneous bags (PSCustomObject, hashtables, or string primitives).
- Content is resolved using `Resolve-BagContent -Item $Item`:
  - Prefers `Content` (canonical descriptor contract).
  - Falls back to `Text` (thread/tp-era contract).
- The key that was read is the key that must be written back, preserving track agnosticism.

### Copy-on-Mutate / Copy-on-Enrich (`Copy-Bag`)
- Processors must **never mutate caller input references in-place**.
- Output items are cloned with modifications using `Copy-Bag` from `bag-helpers.ps1`, ensuring pure functional data flow.

### Receipt Honesty & Processing Audits
- When enabled via `Config.IncludeMeta = $true` (default), processors append a structured record to the item's `Processing` array:
  ```powershell
  @{
      Processor  = 'rs-whitespace'
      Operations = @('lf', 'trim-trailing', 'max-blank-1', 'ensure-final-lf')
      Skipped    = @{ 'nfc' = 'AlreadyNormalized' }
  }
  ```
- **Honest Reporting**: The `Operations` array must only list operations that *actually ran*. Skipped or declined operations are reported in the `Skipped` dictionary with an explicit reason.

### Early Exit Protocol (`_ChainHalt`)
- If a processor encounters a terminal condition (e.g. binary/NUL content in `file-read.ps1` or an unrecoverable parse error), it sets `_ChainHalt = $true` on the returned bag.
- `chain-executor.ps1` detects `_ChainHalt` and skips all subsequent pipeline steps, returning the item for diagnostic routing.

---

## 3. Processor Position Classes

Processors are categorized into four positional tiers:

| Position Class | Role | Example |
|---|---|---|
| **Reader (Head)** | Consumes crawler descriptors; reads bytes from disk; attaches `Content` and `Encoding`; halts on binary/read failure. | [`file-read.ps1`](file-read.ps1) |
| **Content Mutator** | Modifies text content (comment stripping, whitespace normalization, indentation); appends `Processing` audit metadata. | [`rs-whitespace.ps1`](rs-whitespace.ps1), [`rs.ps.strip.ps1`](rs.ps.strip.ps1), [`rs.cs.strip.ps1`](rs.cs.strip.ps1), [`rs-indent.ps1`](rs-indent.ps1) |
| **Enricher (Tail)** | Read-only content inspection placed after *all* mutators; attaches invariant metadata statistics. | [`rs-content_meta.ps1`](rs-content_meta.ps1) |
| **Segmenting Parser** | Decomposes multi-turn documents into discrete exchange envelopes. | [`tp-perplexity.ps1`](tp-perplexity.ps1) |

---

## 4. Directory Layout

```
processors/
├── README.md               # Architecture invariants and standards (this document)
├── chain-executor.ps1      # ISS runtime executor driving compiled processor plans
├── bag-helpers.ps1         # ISS-registered shared functions (Resolve-BagContent, Copy-Bag)
├── file-read.ps1           # Head reader processor
├── rs-whitespace.ps1       # Whitespace normalizer
├── rs.ps.strip.ps1         # AST PowerShell comment stripper
├── rs.cs.strip.ps1         # Regex C# comment stripper
├── rs-indent.ps1           # Code indentation normalizer
├── rs-content_meta.ps1     # Tail content metrics processor
├── tp-perplexity.ps1       # Perplexity thread parser
├── configs/                # Externalized processor configuration schemas and profiles
├── docs/                   # Full reference docstrings for each processor script
└── tests/                  # Isolated unit and integration test suites
```

---

## 5. Testing & Standalone Invocation

When running processor tests outside of an active Colonel ISS:
- Dot-source [`bag-helpers.ps1`](bag-helpers.ps1) and [`tests/_helpers.ps1`](tests/_helpers.ps1) prior to invoking individual processor scripts.
- Execute the test battery with:
  ```powershell
  Get-ChildItem processors/tests/*.tests.ps1 | ForEach-Object { & $_.FullName }
  ```