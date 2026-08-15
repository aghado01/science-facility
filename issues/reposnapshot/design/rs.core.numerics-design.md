# rs.core.numerics — design brief (2026-07-23)

Replaces rs.core.hash + rs.core.lsh + rs.core.measures (G1-broken placeholders,
see `rs-core-numerics-cross-exam-20260723.md`). One module, demand-driven,
G3-verified code only. The composite snapshot
(`D:\aghado01\project-snapshots\jso-jsonl-hashing\`) stays the capability
inventory; this module is a curated pull from it, never a mirror.

## Demand analysis

**Today (only real consumer: rs.core.sharding):**
| Call site | Function | Semantics to preserve |
|---|---|---|
| sharding:298, 647, 1530 | `Get-PathHash` | SHA256 hex of relative path |
| sharding:648 | `Get-ContentHash -Content` | SHA256 hex of content |
| sharding:649 | `Get-SimHash -Text` | 64-bit hex simhash |

**Near-term (thread-corpus track, per thread-corpus-container.md):** near-dup
thread detection → Hamming over simhashes, MinHash/Jaccard-estimate for corpus
dedup; exact-dup keys → content hash.

**No consumer, excluded** (stay in snapshot inventory, pull on demand):
CTPH, TLSH, RollingWindow/CDC chunking, Compare-WithMetric dispatcher,
Manhattan/Chebyshev/Angular/Dice/PrimeFactor, Mahalanobis/KL/JS,
PMI/co-occurrence/entropy family (richest surface = mathdig.measurement;
re-implement traps if ever pulled). RabinKarp rolling hash lives healthy in
jso-hash.ps1 (jso-jackson) — reposnapshot has no rolling-hash demand.

A migration gift: since G1 SimHash always threw, no persisted metadata ever
contained a simhash — changing generations carries **zero** compat burden.

## Module: `rs.core.numerics.psm1`

Function-only public surface; all classes internal (no `using module` burden
on consumers, no class-export hacks). `#Requires -Version 7.5`,
`Set-StrictMode -Version Latest`, no rs.core dependencies (leaf substrate).

**Module-header law (the G3 masked-arithmetic discipline):**
1. Never multiply unmasked on signed types — PS checked arithmetic widens
   overflow to double (silent precision loss, then bitwise-op throw).
   64-bit: widen via `[System.UInt128]`, truncate back to `[ulong]`.
   32-bit: `[uint64]` accumulator with `-band 0xFFFFFFFFul`.
   Byte: `-band 0xFF`, typed `[byte]` end-to-end.
2. Never `x -band (x - 1)` popcount on `[long]` (sign-bit infinite loop).
3. Always parenthesize 2D-array indices: `$dp[($i - 1), $j]`.
4. Class methods take full arg lists (PS ignores default-param values).
5. Char/string equality is explicit: `-ceq` or documented `-eq`.

### Region 1 — identity (exact)
| Export | Source | Notes |
|---|---|---|
| `Get-PathHash` | rs.core.hash (worked) | SHA256 hex, unchanged signature |
| `Get-ContentHash` | rs.core.hash (worked) | SHA256 hex; Content/FilePath param sets, stream path for files |
| `Get-StreamHash` | rs.core.hash (worked) | keep — file-integrity use |
| internal `Fnv1a64` | hashlib-new (UInt128 idiom) | feature hasher for SimHash; export later only on demand |

Name note: `Get-ContentHash` here keeps its original SHA256-hex meaning; the
jso-jackson `Get-ContentHash` (Int64 polynomial) is the name-squatter — flagged
in the cross-exam for rename on the jso side before any shared session.

### Region 2 — signatures (fuzzy)
| Export | Source | Notes |
|---|---|---|
| `Get-SimHash` | hashlib-new SimHash | masked FNV-64 features, precomputed `[ulong[]]` masks; `-Text` signature preserved for sharding:649. Frequency-weighted default; BM25/IDF knobs retained as options (off by default) |
| `Get-MinHashSignature` | hashlib-new MinHash | masked 32-bit seeded FNV; corpus dedup |
| `Get-JaccardEstimate` | hashlib-new EstimateJaccard | positional signature match |

### Region 3 — measures
| Export | Source | Fixes over G1 |
|---|---|---|
| `Get-HammingDistance` | rewrite | `[uint64]` domain; shift-loop popcount (no sign-bit hang); 16-hex-char chunking so >64-bit sigs work instead of throwing |
| `Get-HammingSimilarity` | port | derives MaxBits from sig length instead of `-MaxBits 64` default |
| `Get-JaccardSimilarity` / `Get-JaccardDistance` | port + fix | `[AllowEmptyCollection()]`; J(∅,∅) = 1.0 |
| `Get-LevenshteinDistance` / `-Similarity` | rewrite | parenthesized indices; two-row rolling DP (O(min(m,n)) memory); explicit `-CaseSensitive` (default on, `-ceq`) |
| `Get-CosineSimilarity` | port (worked) | unchanged |

### Tests: `processors/tests/rs-numerics.tests.ps1` (colonel style)
The cross-exam battery becomes the regression suite:
- **Trap regressions**: FNV on 2+ byte input; Pearson-domain byte ops; sign-bit
  Hamming under a 3 s guard; Levenshtein non-empty; empty-set Jaccard.
- **Semantic checks**: SimHash discrimination (near-identical texts Hamming ≪
  unrelated texts); Jaccard-estimate self = 1.0; SHA256 vectors; Levenshtein
  kitten/sitting = 3; case-sensitivity both switch states.
- **Determinism**: fixed inputs → pinned outputs (simhash of a fixture string).

## Migration
1. Add `rs.core.numerics.psm1` + tests.
2. `rs.core.sharding.psm1` lines 29–30: two Import-Module lines → one.
   Call sites unchanged.
3. Delete rs.core.hash/lsh/measures (git history preserves; no .legacy copy —
   the snapshot already archives the generations).
4. CHANGELOG entry; corpus-container note updated ("bind Hashish" → "bind
   rs.core.numerics").

## Naming

`rs.core.numerics` — endorsed. It names the discipline (numeric correctness
under PowerShell semantics), not just the contents; hash + lsh + measures
merge honestly under it; and it gives colonel-bench statistics a natural home
later without a new file. Rejected: `rs.core.hashish` (name belongs to the
broken G1 generation in mathdig — bad associations), `rs.core.lsh` (too
narrow), `rs.core.mensura` (wink spends better on products than substrate).

## System picture

```
snapshot inventory (all generations, reference-only)
        │  curated pull (G3 only)
        ▼
rs.core.numerics.psm1  (leaf; no rs.core deps)
        ▲                    ▲
        │ Import-Module      │ Import-Module (future)
rs.core.sharding      thread-corpus tooling
  (metadata stamps:     (near-dup: SimHash+Hamming,
   pathHash/contentHash/  MinHash+Jaccard; exact-dup:
   simHash per file)      contentHash keys)

jso-jackson/jso-hash.ps1 — separate delivery mode (dot-source, session
surface), same G3 idiom; owns rolling-hash/Rabin-Karp. Cross-referenced,
never merged: module-import substrate vs dot-source session tools.
```
