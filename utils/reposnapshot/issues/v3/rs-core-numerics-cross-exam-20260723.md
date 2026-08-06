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

## ~~Not ported (known gap)~~ — corrected by Part 2

Original claim "no fuzzy/near-dup layer survives anywhere" was wrong: the
corrected fuzzy layer lives in mathdig `hashlib-new.ps1` (see Part 2, verified
working). The corpus-container plan to consolidate from its masked-uint64
patterns is exactly right.

---

# Part 2 — Descendant map (composite snapshot audit, 2026-07-23)

Source: `D:\aghado01\project-snapshots\jso-jsonl-hashing\json-jsonl_20260424_022119_*`
(snapshot dated 2026-04-24). Files extracted by shard byte offsets
(`row_content_end` is **inclusive** — off-by-one truncates the final closer)
and JSON-unescaped, then run through the same empirical battery as Part 1.

## Generations, verified

| Generation | Members | Battery result |
|---|---|---|
| **G1 broken numerics** | `mathdig.hashish.psm1`, `mathdig.measurement.psm1` ≙ rs.core.hash/lsh/measures | Fails **byte-for-byte identically** to rs.core (same FNV overflow, Pearson byte-return, 1-arg GetRollContext, Levenshtein comma-index, Hamming sign-bit hang — reproduced under a 3 s guard). Same generation, not fixes. measurement is a superset sibling: adds Get-CoocurrenceMatrix / PMI / ContextualEntropy / ConditionalProbability. |
| **G2 RabinKarp architecture** | `tooldig.readwrite.psm1`, `context-guardian/storage.psm1` | Right skeleton (uint32 fields, base 257 / mod 1e9+7; AddChar whole-content path correct — `Get-ContentHash('hello')` = 418513571 = jso, and = rs.core `PolynomialHash::Compute`). But **RollWindow is the composed `RemoveChar(); AddChar()`** — empirically `MISMATCH at first roll` (tooldig; storage has the identical composed body, capture too corrupted to execute). tooldig `Find-StringPattern` dangles on missing `hashing-primitives.psm1` (`[Polynomial]` type not found) — exactly what jso-hash's header says it replaced. |
| **G3 corrected — exact/rolling** | `jso-hash.ps1` (jso-jackson) | All green (Part 1). The roll fix (single composed formula, BasePower = base^m, explicit `[long]` casts) first *verifiably* exists here: jso-hash's SOURCE note credits storage.psm1 as "canonical bug-fixed", but the 4/24 snapshot's storage.psm1 still has the broken composed roll — either the fix landed in jso-hash itself or in a post-snapshot storage revision. |
| **G3 corrected — fuzzy/LSH** | `mathdig/hashlib-new.ps1` | **All green.** SimHash `cef7991c1475e5ce`; discrimination real (Hamming 6 for near-identical texts vs 29 for unrelated); CTPH emits proper two-scale ssdeep signature; MinHash + EstimateJaccard work; TLSH emits valid `T1…`. |
| **Reference ports** | `spcx-hashish/*.cs` (simhash, minhash, ctph, tlsh, bm25-stats) | Not executed; C# native unchecked arithmetic sidesteps the PS traps. Study material per corpus-container note. |
| **JSONL/bloom parent** | `jso-utils/Jso-Utils.Core.psm1` | Parses clean; bloom system + JSONL core are jso-jackson's direct parent (accompanying `RepoSnapshot-Jso-utils.core.md` review describes the same hybrid bloom pattern + `script:Get-BloomFilterHashes` placement jso-jackson has). |
| **Corrupted captures** | `context-guardian/hashlib.psm1` (5 parse errors — class header mangled into `function`), `context-guardian/storage.psm1` (1) | Snapshot-time strip corruption; unusable as code, legible as reference. |

## hashlib-new's masked-uint64 idiom (the pattern to consolidate on)

- 64-bit FNV-1a: `[ulong]([System.UInt128]$hash * [System.UInt128]$prime)` —
  widen through UInt128, truncate back; exact wraparound semantics.
- 32-bit seeded FNV: `($hash * $prime) -band 0xFFFFFFFFul` on `[uint64]`.
- Pearson: byte-domain masked `((h -bxor c) * 31) -band 0xFF`, typed `[byte]`
  end-to-end (fixes the G1 byte-return throw).
- Precomputed `[ulong[]] $Masks` instead of per-bit `1L -shl $i`.
- Plus upgrades beyond bugfix: BM25/IDF-weighted SimHash features, compiled
  NonBacktracking `\p{L}\p{Nd}_` tokenizer.

## Consolidation implications

1. Near-dup/fuzzy for the thread corpus: lift from `hashlib-new.ps1`, not
   rs.core.lsh, not mathdig.hashish (both G1-broken). It runs as-is today.
2. A future measures port should take mathdig.measurement as the *surface*
   spec (it's the richest: + PMI/entropy family) but re-implement the three
   trap sites: parenthesize 2D indices, popcount without `x -band (x-1)` on
   signed longs (mask into `[uint64]` or `-shr` loop), `[AllowEmptyCollection()]`.
3. jso-hash's SOURCE header overstates storage.psm1 — worth a one-line
   amendment so the fix provenance isn't mis-attributed later.
4. Snapshot ingest note (reposnapshot): `row_content_end` inclusive; and the
   context-guardian captures show live strip-corruption (class → `function`
   mangling) worth a colonel test case.
