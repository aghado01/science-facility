using namespace System
using namespace System.Collections.Generic
using namespace System.IO
using namespace System.Numerics
using namespace System.Security.Cryptography
using namespace System.Text

#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Numeric primitives for RepoSnapshot: exact identity, fuzzy signatures, and similarity measures.

.DESCRIPTION
    Provides mathematical and hash primitives:
      - Identity: Get-PathHash, Get-ContentHash, Get-StreamHash (SHA256)
      - Signatures: Get-SimHash, Get-DocStats, Get-MinHashSignature, Get-JaccardEstimate
      - Measures: Get-HammingDistance/-Similarity, Get-JaccardSimilarity/-Distance,
                  Get-LevenshteinDistance/-Similarity, Get-CosineSimilarity
#>

#region InternalClasses

class SimHash
{
    static [ulong[]] $Masks = [SimHash]::GenerateMasks()

    static [System.Text.RegularExpressions.Regex] $WordRegex = [System.Text.RegularExpressions.Regex]::new(
        '[\p{L}\p{Nd}_]+',
        [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor
        [System.Text.RegularExpressions.RegexOptions]::NonBacktracking
    )

    hidden [Dictionary[string, double]] $IdfMap
    hidden [double] $AvgDocLength
    hidden [double] $K1
    hidden [double] $B
    hidden [double] $UnknownIdf
    hidden [double] $MinWeight
    hidden [double] $MaxIdf

    static [ulong[]] GenerateMasks()
    {
        [ulong[]]$bitMasks = [ulong[]]::new(64)
        for ([int]$i = 0; $i -lt 64; $i++)
        {
            $bitMasks[$i] = 1ul -shl $i
        }
        return $bitMasks
    }

    # FNV-1a 64-bit with exact wraparound: widen through UInt128, truncate back.
    static [ulong] ComputeFnv1a64Utf8([string]$Value)
    {
        [ulong]$hash = 14695981039346656037ul
        [ulong]$prime = 1099511628211ul
        [byte[]]$bytes = [Encoding]::UTF8.GetBytes($Value)

        foreach ($b in $bytes)
        {
            $hash = $hash -bxor [ulong]$b
            $hash = [ulong]([UInt128]$hash * [UInt128]$prime)
        }

        return $hash
    }

    # Full arg list by design (law 4) — the exported Get-SimHash owns defaults.
    SimHash([hashtable]$Options)
    {
        $this.K1 = [double]($Options['K1'] ?? 1.5)
        if ($this.K1 -lt 0.0) { throw 'K1 must be >= 0.0' }

        $this.B = [double]($Options['B'] ?? 0.75)
        if ($this.B -lt 0.0 -or $this.B -gt 1.0) { throw 'B must be in [0.0, 1.0]' }

        $this.AvgDocLength = [double]($Options['AvgDocLength'] ?? 0.0)
        $this.UnknownIdf = [double]($Options['UnknownIdf'] ?? 0.0)
        $this.MinWeight = [double]($Options['MinWeight'] ?? 1e-6)
        $this.MaxIdf = [double]($Options['MaxIdf'] ?? [double]::PositiveInfinity)
        if ($this.MinWeight -lt 0.0) { throw 'MinWeight must be >= 0.0' }

        [hashtable]$rawMap = $Options['IdfMap'] ?? @{}
        $this.IdfMap = [Dictionary[string, double]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($key in $rawMap.Keys)
        {
            $this.IdfMap[[string]$key] = [double]$rawMap[$key]
        }
    }

    [string] Compute([string]$Text)
    {
        if ([string]::IsNullOrWhiteSpace($Text)) { return '0' * 16 }

        $tokenMatches = [SimHash]::WordRegex.Matches($Text)
        [int]$docLength = $tokenMatches.Count
        if ($docLength -eq 0) { return '0' * 16 }

        [double]$avgLen = if ($this.AvgDocLength -le 0.0) { $docLength } else { $this.AvgDocLength }

        [Dictionary[string, int]]$tfMap = [Dictionary[string, int]]::new([StringComparer]::Ordinal)
        foreach ($match in $tokenMatches)
        {
            [string]$val = $match.Value.ToLowerInvariant()
            [int]$count = 0
            if ($tfMap.TryGetValue($val, [ref]$count)) { $tfMap[$val] = $count + 1 }
            else { $tfMap[$val] = 1 }
        }

        [double[]]$vector = [double[]]::new(64)
        [double]$k1PlusOne = $this.K1 + 1.0
        [double]$docLengthRatio = $this.B * ($docLength / $avgLen)
        [double]$bm25DenomConst = $this.K1 * (1.0 - $this.B + $docLengthRatio)
        [ulong[]]$localMasks = [SimHash]::Masks

        foreach ($kvp in $tfMap.GetEnumerator())
        {
            [string]$token = $kvp.Key
            [int]$tf = $kvp.Value

            [double]$idf = $this.UnknownIdf
            [double]$outIdf = 0.0
            if ($this.IdfMap.TryGetValue($token, [ref]$outIdf)) { $idf = $outIdf }
            if ($idf -lt 0.0) { $idf = 0.0 }
            elseif ($idf -gt $this.MaxIdf) { $idf = $this.MaxIdf }

            [double]$weight = ($idf * $k1PlusOne * $tf) / ($bm25DenomConst + $tf)
            if ($weight -le $this.MinWeight) { continue }

            [ulong]$tokenHash = [SimHash]::ComputeFnv1a64Utf8($token)
            for ([int]$i = 0; $i -lt 64; $i++)
            {
                if (($tokenHash -band $localMasks[$i]) -ne 0ul) { $vector[$i] += $weight }
                else { $vector[$i] -= $weight }
            }
        }

        [ulong]$hash = 0ul
        for ([int]$i = 0; $i -lt 64; $i++)
        {
            if ($vector[$i] -gt 0.0) { $hash = $hash -bor $localMasks[$i] }
        }

        return $hash.ToString('x16')
    }
}

class MinHash
{
    static [uint32[]] Compute([string]$Content, [int]$NumHashes, [int]$ShingleSize)
    {
        if ($NumHashes -le 0) { throw 'NumHashes must be greater than 0' }
        if ($ShingleSize -le 0) { throw 'ShingleSize must be greater than 0' }

        $shingles = [MinHash]::GenerateShingles($Content, $ShingleSize)
        if ($shingles.Count -eq 0)
        {
            return [uint32[]]::new($NumHashes)
        }

        [uint32[]]$signature = [uint32[]]::new($NumHashes)
        for ([int]$i = 0; $i -lt $NumHashes; $i++)
        {
            $signature[$i] = [uint32]::MaxValue
        }

        foreach ($shingle in $shingles)
        {
            for ([int]$i = 0; $i -lt $NumHashes; $i++)
            {
                [uint32]$hash = [MinHash]::HashWithSeed($shingle, $i)
                if ($hash -lt $signature[$i]) { $signature[$i] = $hash }
            }
        }

        return $signature
    }

    static [HashSet[string]] GenerateShingles([string]$Content, [int]$Size)
    {
        $shingles = [HashSet[string]]::new()
        if ([string]::IsNullOrEmpty($Content) -or $Content.Length -lt $Size)
        {
            return $shingles
        }

        for ([int]$i = 0; $i -le $Content.Length - $Size; $i++)
        {
            $null = $shingles.Add($Content.Substring($i, $Size))
        }

        return $shingles
    }

    # Seeded FNV-1a 32-bit in a [uint64] accumulator, masked each round (law 1).
    static [uint32] HashWithSeed([string]$Value, [int]$Seed)
    {
        [uint64]$hash = [uint64](2166136261 + $Seed)
        [uint64]$prime = 16777619ul
        [byte[]]$bytes = [Encoding]::UTF8.GetBytes($Value)

        foreach ($b in $bytes)
        {
            $hash = $hash -bxor [uint64]$b
            $hash = ($hash * $prime) -band 0xFFFFFFFFul
        }

        return [uint32]$hash
    }

    static [double] EstimateJaccard([uint32[]]$Sig1, [uint32[]]$Sig2)
    {
        if ($Sig1.Length -ne $Sig2.Length) { throw 'Signature lengths must match' }

        [int]$matchCount = 0
        for ([int]$i = 0; $i -lt $Sig1.Length; $i++)
        {
            if ($Sig1[$i] -eq $Sig2[$i]) { $matchCount++ }
        }

        return [double]$matchCount / $Sig1.Length
    }
}
#endregion

#region Identity

function Get-PathHash
{
    <#
    .SYNOPSIS
        SHA256 hex (lowercase) of a file path string.
    .EXAMPLE
        Get-PathHash -Path "src/extension.ts"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string]$Path
    )

    process
    {
        [byte[]]$bytes = [Encoding]::UTF8.GetBytes($Path)
        return [Convert]::ToHexString([SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function Get-ContentHash
{
    <#
    .SYNOPSIS
        SHA256 hex (lowercase) of string content or a file's bytes.
    .DESCRIPTION
        -Content hashes the UTF-8 bytes of the string (empty string allowed —
        yields the well-known empty-input digest). -FilePath streams the file.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Content')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Content')]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory, ParameterSetName = 'File')]
        [string]$FilePath
    )

    if ($PSCmdlet.ParameterSetName -eq 'File')
    {
        if (-not [File]::Exists($FilePath))
        {
            throw "Get-ContentHash: file not found: $FilePath"
        }

        $stream = [FileStream]::new($FilePath, [FileMode]::Open, [FileAccess]::Read, [FileShare]::Read)
        try { return [Convert]::ToHexString([SHA256]::HashData($stream)).ToLowerInvariant() }
        finally { $stream.Dispose() }
    }

    [byte[]]$bytes = [Encoding]::UTF8.GetBytes($Content)
    return [Convert]::ToHexString([SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-StreamHash
{
    <#
    .SYNOPSIS
        SHA256 hex (lowercase) of an open stream (memory-efficient).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [Stream]$Stream
    )

    return [Convert]::ToHexString([SHA256]::HashData($Stream)).ToLowerInvariant()
}
#endregion

#region Signatures

function Get-SimHash
{
    <#
    .SYNOPSIS
        64-bit SimHash (16 hex chars) over word features, BM25-saturated
        term-frequency weighting.
    .DESCRIPTION
        With no -IdfMap every token weighs UnknownIdf (default 1.0) — plain
        saturated-TF SimHash, no corpus needed. For corpus-aware weighting,
        build stats once with Get-DocStats and pass its IdfMap/AvgDocLength.
        Whitespace-only input returns the all-zero hash.
        Compare signatures with Get-HammingDistance.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Text,

        [hashtable]$IdfMap = @{},
        [double]$UnknownIdf = 1.0,
        [double]$K1 = 1.5,
        [double]$B = 0.75,
        [double]$AvgDocLength = 0.0,
        [double]$MinWeight = 1e-6,
        [double]$MaxIdf = [double]::PositiveInfinity
    )

    process
    {
        $engine = [SimHash]::new(@{
                IdfMap       = $IdfMap
                UnknownIdf   = $UnknownIdf
                K1           = $K1
                B            = $B
                AvgDocLength = $AvgDocLength
                MinWeight    = $MinWeight
                MaxIdf       = $MaxIdf
            })
        return $engine.Compute($Text)
    }
}

function Get-DocStats
{
    <#
    .SYNOPSIS
        Corpus statistics for IDF-weighted SimHash: AvgDocLength + smoothed
        IdfMap over a document set.
    .EXAMPLE
        $stats = Get-DocStats -Documents $allThreads
        $sig = Get-SimHash -Text $thread -IdfMap $stats.IdfMap -AvgDocLength $stats.AvgDocLength
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Documents
    )

    [int]$docCount = $Documents.Count
    if ($docCount -eq 0)
    {
        return @{ AvgDocLength = 0.0; IdfMap = @{}; DocumentCount = 0 }
    }

    [double]$totalLength = 0.0
    $docFreq = [Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($doc in $Documents)
    {
        $tokenMatches = [SimHash]::WordRegex.Matches($doc)
        $totalLength += $tokenMatches.Count

        $seen = [HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($match in $tokenMatches)
        {
            $null = $seen.Add($match.Value.ToLowerInvariant())
        }

        foreach ($token in $seen)
        {
            [int]$existing = 0
            if ($docFreq.TryGetValue($token, [ref]$existing)) { $docFreq[$token] = $existing + 1 }
            else { $docFreq[$token] = 1 }
        }
    }

    $idfMap = @{}
    foreach ($kvp in $docFreq.GetEnumerator())
    {
        $idfMap[$kvp.Key] = [Math]::Log(($docCount + 1.0) / ($kvp.Value + 1.0)) + 1.0
    }

    return @{
        AvgDocLength  = $totalLength / $docCount
        IdfMap        = $idfMap
        DocumentCount = $docCount
    }
}

function Get-MinHashSignature
{
    <#
    .SYNOPSIS
        MinHash signature (uint32[]) over character shingles, for Jaccard
        similarity estimation via Get-JaccardEstimate.
    .DESCRIPTION
        Content shorter than ShingleSize yields the all-zero signature.
    #>
    [CmdletBinding()]
    [OutputType([uint32[]])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Content,

        [ValidateRange(1, 4096)]
        [int]$NumHashes = 128,

        [ValidateRange(1, 64)]
        [int]$ShingleSize = 3
    )

    process
    {
        return [MinHash]::Compute($Content, $NumHashes, $ShingleSize)
    }
}

function Get-JaccardEstimate
{
    <#
    .SYNOPSIS
        Jaccard similarity estimate [0,1] from two equal-length MinHash
        signatures (fraction of matching positions).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [uint32[]]$Signature1,

        [Parameter(Mandatory)]
        [uint32[]]$Signature2
    )

    return [MinHash]::EstimateJaccard($Signature1, $Signature2)
}
#endregion

#region Measures

function Get-HammingDistance
{
    <#
    .SYNOPSIS
        Count of differing bits between two equal-length hex signatures.
    .DESCRIPTION
        Handles signatures of any length (processed in 64-bit chunks, so
        128-bit+ signatures work). Popcount via BitOperations on [uint64] —
        immune to the signed x -band (x-1) sign-bit loop (law 2).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]+$')]
        [string]$Sig1,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]+$')]
        [string]$Sig2
    )

    if ($Sig1.Length -ne $Sig2.Length)
    {
        throw 'Signatures must have equal length'
    }

    [int]$dist = 0
    [int]$pos = $Sig1.Length
    while ($pos -gt 0)
    {
        [int]$take = [Math]::Min(16, $pos)
        $pos -= $take
        [uint64]$a = [Convert]::ToUInt64($Sig1.Substring($pos, $take), 16)
        [uint64]$b = [Convert]::ToUInt64($Sig2.Substring($pos, $take), 16)
        $dist += [BitOperations]::PopCount($a -bxor $b)
    }

    return $dist
}

function Get-HammingSimilarity
{
    <#
    .SYNOPSIS
        Normalized Hamming similarity [0,1]; bit width derived from the
        signature length (4 bits per hex char).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [string]$Sig1,

        [Parameter(Mandatory)]
        [string]$Sig2
    )

    [int]$dist = Get-HammingDistance -Sig1 $Sig1 -Sig2 $Sig2
    [int]$maxBits = 4 * $Sig1.Length
    return 1.0 - ($dist / $maxBits)
}

function Get-JaccardSimilarity
{
    <#
    .SYNOPSIS
        Jaccard index |A ∩ B| / |A ∪ B| over two sets. J(∅,∅) = 1.0.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Set1,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Set2
    )

    $s1 = [HashSet[object]]::new([object[]]$Set1)
    $s2 = [HashSet[object]]::new([object[]]$Set2)

    $union = [HashSet[object]]::new($s1)
    $union.UnionWith($s2)
    if ($union.Count -eq 0) { return 1.0 }

    $intersection = [HashSet[object]]::new($s1)
    $intersection.IntersectWith($s2)

    return [double]$intersection.Count / $union.Count
}

function Get-JaccardDistance
{
    <#
    .SYNOPSIS
        1 − Jaccard similarity (a proper metric).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Set1,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Set2
    )

    return 1.0 - (Get-JaccardSimilarity -Set1 $Set1 -Set2 $Set2)
}

function Get-LevenshteinDistance
{
    <#
    .SYNOPSIS
        Edit distance (insert/delete/substitute) between two strings.
    .DESCRIPTION
        Two-row rolling DP — O(min-side) memory, 1D indexing (no 2D
        comma-precedence trap, law 3). Case-SENSITIVE by default via code-point
        comparison (law 5); pass -CaseInsensitive for invariant-lowercase
        comparison.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$String1,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$String2,

        [switch]$CaseInsensitive
    )

    if ($CaseInsensitive)
    {
        $String1 = $String1.ToLowerInvariant()
        $String2 = $String2.ToLowerInvariant()
    }

    [int]$n = $String1.Length
    [int]$m = $String2.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }

    [int[]]$previous = [int[]]::new($m + 1)
    [int[]]$current = [int[]]::new($m + 1)
    for ([int]$j = 0; $j -le $m; $j++) { $previous[$j] = $j }

    for ([int]$i = 1; $i -le $n; $i++)
    {
        $current[0] = $i
        [int]$aCode = [int]$String1[($i - 1)]

        for ([int]$j = 1; $j -le $m; $j++)
        {
            [int]$cost = if ($aCode -eq [int]$String2[($j - 1)]) { 0 } else { 1 }
            [int]$deletion = $previous[$j] + 1
            [int]$insertion = $current[($j - 1)] + 1
            [int]$substitution = $previous[($j - 1)] + $cost
            $current[$j] = [Math]::Min([Math]::Min($deletion, $insertion), $substitution)
        }

        $tmp = $previous
        $previous = $current
        $current = $tmp
    }

    return $previous[$m]
}

function Get-LevenshteinSimilarity
{
    <#
    .SYNOPSIS
        Normalized Levenshtein similarity [0,1]: 1 − distance / max-length.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$String1,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$String2,

        [switch]$CaseInsensitive
    )

    [int]$maxLen = [Math]::Max($String1.Length, $String2.Length)
    if ($maxLen -eq 0) { return 1.0 }

    [int]$dist = Get-LevenshteinDistance -String1 $String1 -String2 $String2 -CaseInsensitive:$CaseInsensitive
    return 1.0 - ($dist / $maxLen)
}

function Get-CosineSimilarity
{
    <#
    .SYNOPSIS
        Cosine similarity of two sparse vectors (hashtables key → weight).
        Range [-1,1]; 0.0 when either vector has zero magnitude.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Vector1,

        [Parameter(Mandatory)]
        [hashtable]$Vector2
    )

    [double]$dotProduct = 0.0
    [double]$mag1 = 0.0
    [double]$mag2 = 0.0

    $allKeys = [HashSet[string]]::new([string[]]$Vector1.Keys)
    $allKeys.UnionWith([string[]]$Vector2.Keys)

    foreach ($key in $allKeys)
    {
        [double]$v1 = if ($Vector1.ContainsKey($key)) { [double]$Vector1[$key] } else { 0.0 }
        [double]$v2 = if ($Vector2.ContainsKey($key)) { [double]$Vector2[$key] } else { 0.0 }

        $dotProduct += $v1 * $v2
        $mag1 += $v1 * $v1
        $mag2 += $v2 * $v2
    }

    [double]$magnitude = [Math]::Sqrt($mag1) * [Math]::Sqrt($mag2)
    if ($magnitude -eq 0) { return 0.0 }

    return $dotProduct / $magnitude
}
#endregion

Export-ModuleMember -Function @(
    # Region 1 — identity
    'Get-PathHash',
    'Get-ContentHash',
    'Get-StreamHash',

    # Region 2 — signatures
    'Get-SimHash',
    'Get-DocStats',
    'Get-MinHashSignature',
    'Get-JaccardEstimate',

    # Region 3 — measures
    'Get-HammingDistance',
    'Get-HammingSimilarity',
    'Get-JaccardSimilarity',
    'Get-JaccardDistance',
    'Get-LevenshteinDistance',
    'Get-LevenshteinSimilarity',
    'Get-CosineSimilarity'
)
