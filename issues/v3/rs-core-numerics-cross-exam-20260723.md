# rs.core.hash / lsh / measures × jso-jackson — lineage cross-exam (2026-07-23)

Empirical audit backing the `thread-corpus-container.md` note "Do not use
rs.core.hash/lsh as-is (broken numerics)". Every claim below was executed, not
just read (harness: pwsh 7.5, all rs.core paths exercised via `using module`).

## Lineage verdict

Confirmed direct descent, at the numeric level: `[RabinKarpHash]` (jso-hash.ps1)
and `[PolynomialHash]` (rs.core.hash) produce **identical hashes** for the same
input (base 257, mod 1e9+7; verified `517618891 == 517618891` on `abcdefgh`).
jso-hash is the corrected, slimmed survivor; the fuzzy-LSH and measures layers
were dropped, not ported.

## rs.core defect inventory (all verified at runtime)

Root causes are four PowerShell semantics traps, not algorithm errors:

- **T1 checked arithmetic**: PS widens `long`/`uint32` overflow to `double`
  instead of wrapping. FNV/multiplicative hashes require wraparound.
- **T2 class methods have no default params**: `f($a, $b = @{})` compiles as a
  fixed 2-arg signature; 1-arg calls throw "Cannot find an overload".
- **T3 2D-index comma precedence**: `$dp[$i - 1, $j]` parses as
  `$dp[$i - (1, $j)]` → "op_Subtraction on Object[]".
- **T4 checked return conversion**: int → `[byte]` at method return throws
  instead of truncating.

| Function / class | Status | Cause |
|---|---|---|
| `FNV1a::Compute/ComputeHex` | throws on any input ≥ 2 bytes | T1 (first multiply → double → next `-bxor` fails) |
| `PearsonHash::Compute` | throws on any non-trivial input | T4 (`(h ^ c) * 31` > 255, no `% 256`) |
| `PolynomialHash::GetRollContext(1 arg)` | throws | T2 — and `RollingWindow`'s own ctor makes the 1-arg call, so `RollingWindow`, `Get-RollingHash`, `Get-ContentBoundaryOffsets` are all dead |
| `PolynomialHash::Compute/RollAdd` | **correct** (2-arg ctx) | formulas check out; `long` arithmetic stays in range |
| `Get-LevenshteinDistance` | throws always (non-empty inputs) | T3 → `CTPH::Compare` dead transitively |
| `Get-HammingDistance` | **infinite loop** when sigs differ in bit 63; throws for > 16 hex chars | Kernighan's `x & (x-1)`: `[long]::MinValue - 1` → double → rounds back to MinValue → loop invariant. ~50 % of random SimHash pairs hang |
| `Get-JaccardSimilarity` | rejects empty sets | Mandatory binding, no `[AllowEmptyCollection()]`; also J(∅,∅)=0 (convention: 1) |
| `SimHash`, `CTPH`, `MinHash`, `TLSH` | all throw | T1/T4 transitively (MinHash's own seeded FNV overflows too) |
| `Get-SimHash`, `Get-FuzzyHash`, `Find-SimilarContent` | dead | all four algorithms broken |
| SHA256 paths (`SHA256Hash`, `Get-ContentHash`, `Get-PathHash`, `Get-StreamHash`, `Get-BlockHashes -Algorithm SHA256`) | **work** | .NET crypto, no PS arithmetic |
| Vector/statistical measures (Cosine verified; Manhattan/Euclidean/Chebyshev/KL/JS same double-math shape) | work | plain double math |

Live consumer: `rs.core.sharding.psm1` imports hash+lsh with `-ErrorAction
Stop` and `Build-ShardMetadata` calls SimHash — already flagged in
thread-corpus-container.md ("flag off or bind Hashish").

## What the descendant fixed (verified)

- **Working rolling hash**: `RollWindow` (multiply-first formula, BasePower =
  base^m, explicit `[long]` intermediates) matches fresh recompute across a
  full sliding pass. The ancestor's roll surface never ran.
- **Overflow-safe FNV**: bloom filter's `Get-BloomFilterHashes` uses 32-bit
  FNV-1a + djb2 with explicit `% 2^32` on `uint64` — immune to T1.
- **Case-sensitivity awareness**: `Find-StringPattern` verifies with `-ceq`
  (PS `-eq` on chars is case-insensitive — verified). Overlap + boundary
  matches correct (`aaaa`/`aa` → 0,1,2).
- **Bloom sizing exact**: m=95851, k=7 for n=10k/p=0.01 matches theory;
  0 false negatives observed.

## Descendant nits (jso-jackson side, none blocking)

1. `Get-ContentHash -WindowSize` is a **no-op** (AddChar never uses BasePower;
   verified w4 == w64). Doc claims it "affects hash distribution". Also:
   30-bit effective range → birthday collisions ~38k items; whitespace-only
   content → sentinel `0L`.
2. `Find-JsonlDuplicates -Verify` is a stub: stores the key as its own value,
   `Verified` is always `$true` — never detects a hash collision.
3. jso-hash header lists `RemoveChar` in the class surface; no such method.
4. Bloom comment says "FNV-1"; code is FNV-1a (xor-then-multiply).
5. `Read-BloomFilter` min-size guard is 32; actual header is 36 bytes.
6. Observed FPR at full load ≈ 2.15 % vs nominal 1 % (double-hashing
   degradation + correlated short keys). No-false-negative guarantee holds,
   and all workflows confirm via exact dict/HashSet anyway.
7. Name collision pending centralization: jso `Get-ContentHash` (Int64
   polynomial) vs rs.core `Get-ContentHash` (SHA256 hex) — same name, different
   algorithm and return type. Rename one before the two ever share a session.

## Not ported (known gap)

No fuzzy/near-dup layer survives anywhere: SimHash/MinHash/CTPH/TLSH are dead
in the ancestor and have no descendant. Matches the corpus-container plan to
consolidate near-dup hashing from mathdig `hashlib-new.ps1` masked-uint64
patterns instead.
