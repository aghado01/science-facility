using namespace System
using namespace System.Collections.Generic

#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unified distance and similarity metrics for RepoSnapshot

.DESCRIPTION
    Central hub for all comparison functions, organized by data type:

    ┌──────────────────────────────────────────────────────────────┐
    │  DATA TYPE        │  DISTANCE           │  SIMILARITY        │
    ├──────────────────────────────────────────────────────────────┤
    │  Bit (hashes)     │  Hamming            │  HammingSimilarity │
    │  Set              │  Jaccard (1-sim)    │  Jaccard, Dice     │
    │  String           │  Levenshtein        │  (normalized)      │
    │  Vector           │  Manhattan, Euclid  │  Cosine, Angular   │
    │                   │  Chebyshev, Angular │                    │
    │  Statistical      │  Mahalanobis        │  KL, JS divergence │
    │  Specialized      │  PrimeFactor        │                    │
    └──────────────────────────────────────────────────────────────┘

    USAGE PATTERN:
    - LSH algorithms (SimHash, MinHash, etc.) call these metrics
    - SPC clustering calls these metrics
    - User code picks the appropriate metric for their data type

.NOTES
    Module: rs.core.measures
    Dependencies: None (pure math)
#>

# ==================== BIT-LEVEL METRICS ====================
# Use for: SimHash, TLSH, any bit-vector comparisons

function Get-HammingDistance {
    <#
    .SYNOPSIS
        Count differing bits between two hex-encoded hashes
    .DESCRIPTION
        Essential metric for SimHash comparison.
        Low distance = high similarity.
    .EXAMPLE
        $dist = Get-HammingDistance -Sig1 "abc123def456" -Sig2 "abc125def456"
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Sig1,

        [Parameter(Mandatory)]
        [string]$Sig2
    )

    if ($Sig1.Length -ne $Sig2.Length) {
        throw "Signatures must have equal length"
    }

    $n1 = [Convert]::ToInt64($Sig1, 16)
    $n2 = [Convert]::ToInt64($Sig2, 16)
    $xor = $n1 -bxor $n2

    # Kernighan's popcount algorithm
    $dist = 0
    while ($xor -ne 0) {
        $dist++
        $xor = $xor -band ($xor - 1)
    }

    return $dist
}

function Get-HammingSimilarity {
    <#
    .SYNOPSIS
        Normalized Hamming similarity [0,1]
    .DESCRIPTION
        Returns 1.0 for identical hashes, 0.0 for completely different.
        Similarity = 1 - (distance / max_bits)
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [string]$Sig1,

        [Parameter(Mandatory)]
        [string]$Sig2,

        [int]$MaxBits = 64
    )

    $dist = Get-HammingDistance -Sig1 $Sig1 -Sig2 $Sig2
    return 1.0 - ($dist / $MaxBits)
}

# ==================== SET-BASED METRICS ====================
# Use for: MinHash comparison, dependency overlap, tag similarity

function Get-JaccardSimilarity {
    <#
    .SYNOPSIS
        Jaccard index: |A ∩ B| / |A ∪ B|
    .DESCRIPTION
        Measures set overlap. Range [0,1], where 1 = identical sets.
        MinHash signatures estimate this efficiently for large sets.
    .EXAMPLE
        $sim = Get-JaccardSimilarity -Set1 @('a','b','c') -Set2 @('b','c','d')
        # Returns: 0.5 (2 shared out of 4 unique)
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [array]$Set1,

        [Parameter(Mandatory)]
        [array]$Set2
    )

    $s1 = [HashSet[object]]::new($Set1)
    $s2 = [HashSet[object]]::new($Set2)

    $intersection = [HashSet[object]]::new($s1)
    $intersection.IntersectWith($s2)

    $union = [HashSet[object]]::new($s1)
    $union.UnionWith($s2)

    if ($union.Count -eq 0) { return 0.0 }

    return [double]$intersection.Count / $union.Count
}

function Get-JaccardDistance {
    <#
    .SYNOPSIS
        Jaccard distance: 1 - Jaccard similarity
    .DESCRIPTION
        Proper metric (satisfies triangle inequality).
        Use when you need a distance rather than similarity.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [array]$Set1,

        [Parameter(Mandatory)]
        [array]$Set2
    )

    return 1.0 - (Get-JaccardSimilarity -Set1 $Set1 -Set2 $Set2)
}

function Get-SorensenDiceCoefficient {
    <#
    .SYNOPSIS
        Sørensen-Dice coefficient: 2·|A ∩ B| / (|A| + |B|)
    .DESCRIPTION
        Alternative to Jaccard, gives more weight to intersection.
        Often preferred for text similarity (n-gram overlap).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [array]$Set1,

        [Parameter(Mandatory)]
        [array]$Set2
    )

    $s1 = [HashSet[object]]::new($Set1)
    $s2 = [HashSet[object]]::new($Set2)

    $intersection = [HashSet[object]]::new($s1)
    $intersection.IntersectWith($s2)

    $denominator = $s1.Count + $s2.Count
    if ($denominator -eq 0) { return 0.0 }

    return (2.0 * $intersection.Count) / $denominator
}

# ==================== STRING METRICS ====================
# Use for: Fuzzy string matching, typo detection

function Get-LevenshteinDistance {
    <#
    .SYNOPSIS
        Edit distance (insertions, deletions, substitutions)
    .DESCRIPTION
        Minimum operations to transform String1 into String2.
        Used by CTPH for comparing hash sequences.
    .EXAMPLE
        $dist = Get-LevenshteinDistance -String1 "kitten" -String2 "sitting"
        # Returns: 3
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$String1,

        [Parameter(Mandatory)]
        [string]$String2
    )

    $m = $String1.Length
    $n = $String2.Length

    if ($m -eq 0) { return $n }
    if ($n -eq 0) { return $m }

    $dp = New-Object 'int[,]' ($m + 1), ($n + 1)

    for ($i = 0; $i -le $m; $i++) { $dp[$i, 0] = $i }
    for ($j = 0; $j -le $n; $j++) { $dp[0, $j] = $j }

    for ($i = 1; $i -le $m; $i++) {
        for ($j = 1; $j -le $n; $j++) {
            $cost = if ($String1[$i - 1] -eq $String2[$j - 1]) { 0 } else { 1 }
            $dp[$i, $j] = [Math]::Min(
                [Math]::Min($dp[$i - 1, $j] + 1, $dp[$i, $j - 1] + 1),
                $dp[$i - 1, $j - 1] + $cost
            )
        }
    }

    return $dp[$m, $n]
}

function Get-LevenshteinSimilarity {
    <#
    .SYNOPSIS
        Normalized Levenshtein similarity [0,1]
    .DESCRIPTION
        Similarity = 1 - (distance / max_length)
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [string]$String1,

        [Parameter(Mandatory)]
        [string]$String2
    )

    $maxLen = [Math]::Max($String1.Length, $String2.Length)
    if ($maxLen -eq 0) { return 1.0 }

    $dist = Get-LevenshteinDistance -String1 $String1 -String2 $String2
    return 1.0 - ($dist / $maxLen)
}

# ==================== VECTOR METRICS ====================
# Use for: Feature vectors, embeddings, numeric profiles

function Get-ManhattanDistance {
    <#
    .SYNOPSIS
        L1 norm (taxicab distance): Σ|pi - qi|
    .DESCRIPTION
        Sum of absolute differences. Robust to outliers.
        Good for sparse vectors and when all dimensions matter equally.
    .EXAMPLE
        $v1 = @{ 'a' = 1; 'b' = 2; 'c' = 3 }
        $v2 = @{ 'a' = 4; 'b' = 5; 'c' = 6 }
        $dist = Get-ManhattanDistance -Vector1 $v1 -Vector2 $v2
        # Returns: 9
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Vector1,

        [Parameter(Mandatory)]
        [hashtable]$Vector2
    )

    $sum = 0.0
    $allKeys = [HashSet[string]]::new([string[]]$Vector1.Keys)
    $allKeys.UnionWith([string[]]$Vector2.Keys)

    foreach ($key in $allKeys) {
        $v1 = if ($Vector1.ContainsKey($key)) { $Vector1[$key] } else { 0 }
        $v2 = if ($Vector2.ContainsKey($key)) { $Vector2[$key] } else { 0 }
        $sum += [Math]::Abs($v1 - $v2)
    }

    return $sum
}

function Get-EuclideanDistance {
    <#
    .SYNOPSIS
        L2 norm: √(Σ(pi - qi)²)
    .DESCRIPTION
        Standard geometric distance. Most common for dense vectors.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Vector1,

        [Parameter(Mandatory)]
        [hashtable]$Vector2
    )

    $sumSquares = 0.0
    $allKeys = [HashSet[string]]::new([string[]]$Vector1.Keys)
    $allKeys.UnionWith([string[]]$Vector2.Keys)

    foreach ($key in $allKeys) {
        $v1 = if ($Vector1.ContainsKey($key)) { $Vector1[$key] } else { 0 }
        $v2 = if ($Vector2.ContainsKey($key)) { $Vector2[$key] } else { 0 }
        $diff = $v1 - $v2
        $sumSquares += $diff * $diff
    }

    return [Math]::Sqrt($sumSquares)
}

function Get-ChebyshevDistance {
    <#
    .SYNOPSIS
        L∞ norm (chessboard distance): max|pi - qi|
    .DESCRIPTION
        Maximum difference in any dimension.
        Useful when worst-case deviation matters.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Vector1,

        [Parameter(Mandatory)]
        [hashtable]$Vector2
    )

    $maxDiff = 0.0
    $allKeys = [HashSet[string]]::new([string[]]$Vector1.Keys)
    $allKeys.UnionWith([string[]]$Vector2.Keys)

    foreach ($key in $allKeys) {
        $v1 = if ($Vector1.ContainsKey($key)) { $Vector1[$key] } else { 0 }
        $v2 = if ($Vector2.ContainsKey($key)) { $Vector2[$key] } else { 0 }
        $diff = [Math]::Abs($v1 - $v2)
        if ($diff -gt $maxDiff) { $maxDiff = $diff }
    }

    return $maxDiff
}

function Get-CosineSimilarity {
    <#
    .SYNOPSIS
        Cosine similarity: (A · B) / (|A| × |B|)
    .DESCRIPTION
        Measures angle between vectors, ignoring magnitude.
        Range [-1, 1] where 1 = same direction, 0 = orthogonal, -1 = opposite.
        Perfect for TF-IDF vectors and embeddings.
    .EXAMPLE
        $v1 = @{ 'term1' = 3; 'term2' = 4 }
        $v2 = @{ 'term1' = 6; 'term2' = 8 }
        $sim = Get-CosineSimilarity -Vector1 $v1 -Vector2 $v2
        # Returns: 1.0 (same direction, different magnitude)
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Vector1,

        [Parameter(Mandatory)]
        [hashtable]$Vector2
    )

    $dotProduct = 0.0
    $mag1 = 0.0
    $mag2 = 0.0

    $allKeys = [HashSet[string]]::new([string[]]$Vector1.Keys)
    $allKeys.UnionWith([string[]]$Vector2.Keys)

    foreach ($key in $allKeys) {
        $v1 = if ($Vector1.ContainsKey($key)) { [double]$Vector1[$key] } else { 0.0 }
        $v2 = if ($Vector2.ContainsKey($key)) { [double]$Vector2[$key] } else { 0.0 }

        $dotProduct += $v1 * $v2
        $mag1 += $v1 * $v1
        $mag2 += $v2 * $v2
    }

    $magnitude = [Math]::Sqrt($mag1) * [Math]::Sqrt($mag2)
    if ($magnitude -eq 0) { return 0.0 }

    return $dotProduct / $magnitude
}

function Get-CosineDistance {
    <#
    .SYNOPSIS
        Cosine distance: 1 - cosine similarity
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Vector1,

        [Parameter(Mandatory)]
        [hashtable]$Vector2
    )

    return 1.0 - (Get-CosineSimilarity -Vector1 $Vector1 -Vector2 $Vector2)
}

function Get-AngularDistance {
    <#
    .SYNOPSIS
        Angular distance: arccos(similarity) / π
    .DESCRIPTION
        True metric derived from cosine similarity.
        Range [0, 1]: 0 = identical, 0.5 = orthogonal, 1 = opposite

        Unlike cosine distance, this satisfies triangle inequality,
        making it a proper distance metric.
    .EXAMPLE
        $dist = Get-AngularDistance -Vector1 @{x=1;y=0} -Vector2 @{x=0;y=1}
        # Returns: 0.5 (90° / 180° = 0.5)
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Vector1,

        [Parameter(Mandatory)]
        [hashtable]$Vector2
    )

    $similarity = Get-CosineSimilarity -Vector1 $Vector1 -Vector2 $Vector2

    # Clamp to [-1, 1] to handle floating point errors
    $similarity = [Math]::Max(-1.0, [Math]::Min(1.0, $similarity))

    return [Math]::Acos($similarity) / [Math]::PI
}

# ==================== STATISTICAL METRICS ====================
# Use for: Anomaly detection, distribution comparison

function Get-MahalanobisDistance {
    <#
    .SYNOPSIS
        Distance accounting for correlation structure
    .DESCRIPTION
        Uses running statistics (Welford's algorithm format).
        High values indicate anomalies relative to the distribution.
    .PARAMETER Mean
        Running mean per dimension (hashtable)
    .PARAMETER M2
        Running sum of squared deviations per dimension
    .PARAMETER Count
        Number of observations seen
    .PARAMETER Vector
        The observation to measure distance for
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Mean,

        [Parameter(Mandatory)]
        [hashtable]$M2,

        [Parameter(Mandatory)]
        [int]$Count,

        [Parameter(Mandatory)]
        [hashtable]$Vector
    )

    if ($Count -lt 2) { return 0.0 }

    $sumSqDist = 0.0

    foreach ($key in $Vector.Keys) {
        $value = [double]$Vector[$key]
        $mean = if ($Mean.ContainsKey($key)) { [double]$Mean[$key] } else { 0.0 }
        $m2 = if ($M2.ContainsKey($key)) { [double]$M2[$key] } else { 0.0 }

        # Variance = M2 / (Count - 1)
        $variance = $m2 / ($Count - 1)
        if ($variance -gt 0) {
            $diff = $value - $mean
            $sumSqDist += ($diff * $diff) / $variance
        }
    }

    return [Math]::Sqrt($sumSqDist)
}

function Get-KLDivergence {
    <#
    .SYNOPSIS
        Kullback-Leibler divergence: D_KL(P || Q)
    .DESCRIPTION
        Asymmetric measure of how P differs from Q.
        Used for comparing probability distributions.
        Note: Not a true distance (asymmetric, unbounded).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [double[]]$P,

        [Parameter(Mandatory)]
        [double[]]$Q
    )

    $epsilon = 1e-10
    $kl = 0.0

    for ($i = 0; $i -lt $P.Length; $i++) {
        $p = [Math]::Max($P[$i], $epsilon)
        $q = [Math]::Max($Q[$i], $epsilon)
        if ($p -gt $epsilon) {
            $kl += $p * [Math]::Log($p / $q)
        }
    }

    return $kl
}

function Get-JSDivergence {
    <#
    .SYNOPSIS
        Jensen-Shannon divergence (symmetric, bounded)
    .DESCRIPTION
        JS(P || Q) = 0.5 * KL(P || M) + 0.5 * KL(Q || M)
        where M = (P + Q) / 2

        Range [0, ln(2)] for natural log, or [0, 1] for log base 2.
        Symmetric and always finite - better than KL for comparisons.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [double[]]$P,

        [Parameter(Mandatory)]
        [double[]]$Q
    )

    # Compute M = (P + Q) / 2
    $M = [double[]]::new($P.Length)
    for ($i = 0; $i -lt $P.Length; $i++) {
        $M[$i] = 0.5 * ($P[$i] + $Q[$i])
    }

    $klPM = Get-KLDivergence -P $P -Q $M
    $klQM = Get-KLDivergence -P $Q -Q $M

    return 0.5 * ($klPM + $klQM)
}

# ==================== SPECIALIZED METRICS ====================

function Get-PrimeFactorSimilarity {
    <#
    .SYNOPSIS
        Compare prime factorizations using set or vector similarity
    .DESCRIPTION
        Compares prime factorization hashtables.
        Useful for number theory applications and integer similarity.
    .PARAMETER Factorization1
        Prime factorization as hashtable: @{2=3; 5=1; 7=2} means 2^3 * 5^1 * 7^2
    .PARAMETER Factorization2
        Prime factorization to compare against
    .PARAMETER Metric
        Similarity metric: Cosine (on exponents), Jaccard, or Dice (on multiset)
    .EXAMPLE
        $f1 = @{2=3; 5=1; 7=2}  # 2^3 * 5 * 7^2
        $f2 = @{2=1; 5=2; 11=1} # 2 * 5^2 * 11
        $sim = Get-PrimeFactorSimilarity -Factorization1 $f1 -Factorization2 $f2 -Metric Cosine
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Factorization1,

        [Parameter(Mandatory)]
        [hashtable]$Factorization2,

        [ValidateSet('Jaccard','Dice','Cosine')]
        [string]$Metric = 'Cosine'
    )

    # Cosine works on exponent vectors directly
    if ($Metric -eq 'Cosine') {
        return Get-CosineSimilarity -Vector1 $Factorization1 -Vector2 $Factorization2
    }

    # For set-based, expand to multiset
    $set1 = foreach ($p in $Factorization1.GetEnumerator()) {
        1..$p.Value | ForEach-Object { $p.Key }
    }
    $set2 = foreach ($p in $Factorization2.GetEnumerator()) {
        1..$p.Value | ForEach-Object { $p.Key }
    }

    if ($Metric -eq 'Jaccard') {
        return Get-JaccardSimilarity -Set1 $set1 -Set2 $set2
    } else {
        return Get-SorensenDiceCoefficient -Set1 $set1 -Set2 $set2
    }
}

# ==================== UTILITY: GENERIC COMPARISON ====================

function Compare-WithMetric {
    <#
    .SYNOPSIS
        Generic comparison dispatcher
    .DESCRIPTION
        Allows LSH algorithms and other code to request comparison
        by metric name without hardcoding the function.
    .PARAMETER Data1
        First item to compare
    .PARAMETER Data2
        Second item to compare
    .PARAMETER Metric
        Name of metric: Hamming, Jaccard, Cosine, Euclidean, Manhattan, Levenshtein, Angular
    .PARAMETER AsDistance
        If true, returns distance (lower = more similar)
        If false, returns similarity (higher = more similar)
    .EXAMPLE
        $sim = Compare-WithMetric -Data1 $hash1 -Data2 $hash2 -Metric 'Hamming'
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        $Data1,

        [Parameter(Mandatory)]
        $Data2,

        [Parameter(Mandatory)]
        [ValidateSet('Hamming', 'Jaccard', 'Dice', 'Cosine', 'Angular', 'Euclidean', 'Manhattan', 'Chebyshev', 'Levenshtein')]
        [string]$Metric,

        [switch]$AsDistance
    )

    $result = switch ($Metric) {
        'Hamming' {
            if ($AsDistance) {
                Get-HammingDistance -Sig1 $Data1 -Sig2 $Data2
            } else {
                Get-HammingSimilarity -Sig1 $Data1 -Sig2 $Data2
            }
        }
        'Jaccard' {
            if ($AsDistance) {
                Get-JaccardDistance -Set1 $Data1 -Set2 $Data2
            } else {
                Get-JaccardSimilarity -Set1 $Data1 -Set2 $Data2
            }
        }
        'Dice' {
            $sim = Get-SorensenDiceCoefficient -Set1 $Data1 -Set2 $Data2
            if ($AsDistance) { 1.0 - $sim } else { $sim }
        }
        'Cosine' {
            if ($AsDistance) {
                Get-CosineDistance -Vector1 $Data1 -Vector2 $Data2
            } else {
                Get-CosineSimilarity -Vector1 $Data1 -Vector2 $Data2
            }
        }
        'Angular' {
            if ($AsDistance) {
                Get-AngularDistance -Vector1 $Data1 -Vector2 $Data2
            } else {
                1.0 - (Get-AngularDistance -Vector1 $Data1 -Vector2 $Data2)
            }
        }
        'Euclidean' {
            $dist = Get-EuclideanDistance -Vector1 $Data1 -Vector2 $Data2
            if ($AsDistance) { $dist } else { 1.0 / (1.0 + $dist) }
        }
        'Manhattan' {
            $dist = Get-ManhattanDistance -Vector1 $Data1 -Vector2 $Data2
            if ($AsDistance) { $dist } else { 1.0 / (1.0 + $dist) }
        }
        'Chebyshev' {
            $dist = Get-ChebyshevDistance -Vector1 $Data1 -Vector2 $Data2
            if ($AsDistance) { $dist } else { 1.0 / (1.0 + $dist) }
        }
        'Levenshtein' {
            if ($AsDistance) {
                Get-LevenshteinDistance -String1 $Data1 -String2 $Data2
            } else {
                Get-LevenshteinSimilarity -String1 $Data1 -String2 $Data2
            }
        }
    }

    return $result
}

# ==================== EXPORTS ====================

Export-ModuleMember -Function @(
    # Bit-level
    'Get-HammingDistance',
    'Get-HammingSimilarity',

    # Set-based
    'Get-JaccardSimilarity',
    'Get-JaccardDistance',
    'Get-SorensenDiceCoefficient',

    # String
    'Get-LevenshteinDistance',
    'Get-LevenshteinSimilarity',

    # Vector
    'Get-ManhattanDistance',
    'Get-EuclideanDistance',
    'Get-ChebyshevDistance',
    'Get-CosineSimilarity',
    'Get-CosineDistance',
    'Get-AngularDistance',

    # Statistical
    'Get-MahalanobisDistance',
    'Get-KLDivergence',
    'Get-JSDivergence',

    # Specialized
    'Get-PrimeFactorSimilarity',

    # Generic dispatcher
    'Compare-WithMetric'
)
