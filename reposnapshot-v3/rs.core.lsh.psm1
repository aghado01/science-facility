using namespace System
using namespace System.Collections.Generic
using namespace System.IO
using namespace System.Text

using module .\rs.core.hash.psm1
using module .\rs.core.measures.psm1

#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Fuzzy hashing for content similarity detection

.DESCRIPTION
    Implements locality-sensitive hashing techniques:
    - SimHash - Bit-vector LSH for document similarity
    - CTPH (Context-Triggered Piecewise Hashing) - ssdeep-style
    - MinHash - Jaccard similarity approximation
    - TLSH - Trend Micro Locality Sensitive Hash

    Unlike cryptographic hashes (SHA256), these produce similar outputs
    for similar inputs, enabling fuzzy matching and associative recall.

.NOTES
    Based on:
    - SimHash: Charikar's simhash algorithm
    - ssdeep/CTPH: https://www.sei.cmu.edu/blog/fuzzy-hashing-techniques-in-applied-malware-analysis/
    - MinHash: https://graphics.stanford.edu/courses/cs468-06-fall/Papers/13%20lsh06.pdf
    - TLSH: https://github.com/trendmicro/tlsh

    Dependencies:
    - rs.core.hash (FNV1a, PearsonHash)
    - rs.core.measures (LevenshteinDistance, etc.)
#>

# ==================== SIMHASH (LOCALITY-SENSITIVE HASHING) ====================

class SimHash {
    <#
    .SYNOPSIS
        SimHash for near-duplicate detection
    .DESCRIPTION
        Produces 64-bit hash where similar documents have similar hashes.
        Compare using Hamming distance - low distance = high similarity.
    #>

    static [int] $DefaultHashBits = 64
    static [string[]] $StopWords = @(
        'the', 'a', 'an', 'and', 'or', 'but', 'in', 'on', 'at', 'to', 'for',
        'of', 'with', 'by', 'from', 'as', 'is', 'was', 'are', 'were', 'be',
        'been', 'being', 'have', 'has', 'had', 'do', 'does', 'did', 'will',
        'would', 'should', 'could', 'may', 'might', 'must', 'can'
    )

    static [string] Compute([string]$Text, [hashtable]$Options = @{}) {
        $hashBits = if ($Options.ContainsKey('HashBits')) { $Options.HashBits } else { [SimHash]::DefaultHashBits }
        $removeStopWords = if ($Options.ContainsKey('RemoveStopWords')) { $Options.RemoveStopWords } else { $true }

        # Extract features (tokens)
        $features = [SimHash]::ExtractFeatures($Text, $removeStopWords)

        if ($features.Count -eq 0) {
            return '0' * ($hashBits / 4) # Return zero hash in hex
        }

        # Initialize bit vector
        $vector = New-Object 'int[]' $hashBits

        # Accumulate weighted hashes
        foreach ($feature in $features.GetEnumerator()) {
            $token = $feature.Key
            $weight = $feature.Value

            # Hash the token using FNV1a from rs.core.hash
            $tokenHash = [FNV1a]::Compute($token)

            # Update vector based on hash bits
            for ($i = 0; $i -lt $hashBits; $i++) {
                $bit = ($tokenHash -band (1L -shl $i)) -ne 0
                if ($bit) {
                    $vector[$i] += $weight
                } else {
                    $vector[$i] -= $weight
                }
            }
        }

        # Convert vector to hash
        $hash = 0L
        for ($i = 0; $i -lt $hashBits; $i++) {
            if ($vector[$i] -gt 0) {
                $hash = $hash -bor (1L -shl $i)
            }
        }

        return [Convert]::ToString($hash, 16).PadLeft($hashBits / 4, '0')
    }

    static [hashtable] ExtractFeatures([string]$Text, [bool]$RemoveStopWords) {
        $features = @{}

        # Tokenize (simple whitespace + punctuation split)
        $tokens = $Text -split '\W+' | Where-Object { $_.Length -gt 0 }

        foreach ($token in $tokens) {
            $lower = $token.ToLowerInvariant()

            # Skip stop words if requested
            if ($RemoveStopWords -and $lower -in [SimHash]::StopWords) {
                continue
            }

            # Increment weight
            if ($features.ContainsKey($lower)) {
                $features[$lower]++
            } else {
                $features[$lower] = 1
            }
        }

        return $features
    }
}

# ==================== CTPH (CONTEXT-TRIGGERED PIECEWISE HASHING) ====================

class CTPH {
    <#
    .SYNOPSIS
        ssdeep-style context-triggered piecewise hashing
    .DESCRIPTION
        Rolling hash triggers boundary points at modulus matches.
        Similar content triggers boundaries at similar positions,
        producing comparable hash sequences even with insertions/deletions.

        Example:
        "The quick brown fox" → "3:abc:xyz"
        "The very quick brown fox" → "3:abc:xyz" (similar!)
    #>

    static [int] $MinBlockSize = 3
    static [int] $MaxBlockSize = 96

    static [string] Compute([string]$Content, [hashtable]$Options = @{}) {
        if ([string]::IsNullOrEmpty($Content)) {
            return "0::"
        }

        # Auto-select block size based on content length
        $blockSize = [CTPH]::SelectBlockSize($Content.Length)
        if ($Options.ContainsKey('BlockSize')) {
            $blockSize = $Options.BlockSize
        }

        # Compute chunk hashes
        $chunks = [CTPH]::ComputeChunks($Content, $blockSize)

        # Build ssdeep-style signature: blocksize:hash1:hash2
        $hash1 = [CTPH]::HashSequence($chunks)

        # Double block size for second hash (provides scale invariance)
        $chunks2 = [CTPH]::ComputeChunks($Content, $blockSize * 2)
        $hash2 = [CTPH]::HashSequence($chunks2)

        return "${blockSize}:${hash1}:${hash2}"
    }

    static [int] SelectBlockSize([int]$ContentLength) {
        # ssdeep formula: block_size = 3 + log2(input_size / 64)
        if ($ContentLength -lt 4096) {
            return [CTPH]::MinBlockSize
        }

        $blockSize = [Math]::Max(
            [CTPH]::MinBlockSize,
            [int][Math]::Ceiling([Math]::Log($ContentLength / 64, 2))
        )

        return [Math]::Min($blockSize, [CTPH]::MaxBlockSize)
    }

    static [List[long]] ComputeChunks([string]$Content, [int]$BlockSize) {
        $chunks = [List[long]]::new()

        # Rolling hash with FNV1a
        $hash = [long]-3750763034362895579
        $prime = [long]1099511628211
        $windowStart = 0

        for ($i = 0; $i -lt $Content.Length; $i++) {
            # Update rolling hash
            $hash = $hash -bxor [byte]$Content[$i]
            $hash = $hash * $prime

            # Trigger boundary when hash % blockSize == (blockSize - 1)
            if (($hash % $BlockSize) -eq ($BlockSize - 1)) {
                # Capture chunk hash
                $chunkContent = $Content.Substring($windowStart, $i - $windowStart + 1)
                $chunkHash = [CTPH]::HashChunk($chunkContent)
                $chunks.Add($chunkHash)
                $windowStart = $i + 1
            }
        }

        # Final chunk
        if ($windowStart -lt $Content.Length) {
            $chunkContent = $Content.Substring($windowStart)
            $chunkHash = [CTPH]::HashChunk($chunkContent)
            $chunks.Add($chunkHash)
        }

        return $chunks
    }

    static [long] HashChunk([string]$Chunk) {
        # Simple FNV1a hash of chunk
        $hash = [long]-3750763034362895579
        $prime = [long]1099511628211

        foreach ($char in $Chunk.ToCharArray()) {
            $hash = $hash -bxor [byte]$char
            $hash = $hash * $prime
        }

        return $hash
    }

    static [string] HashSequence([List[long]]$Chunks) {
        # Convert chunk sequence to base64-encoded string
        if ($Chunks.Count -eq 0) {
            return ""
        }

        # Limit to 64 chunks (ssdeep convention)
        $maxChunks = [Math]::Min($Chunks.Count, 64)
        $bytes = [byte[]]::new($maxChunks * 8)

        for ($i = 0; $i -lt $maxChunks; $i++) {
            $chunkBytes = [BitConverter]::GetBytes($Chunks[$i])
            [Array]::Copy($chunkBytes, 0, $bytes, $i * 8, 8)
        }

        # Base64 encode and truncate
        $base64 = [Convert]::ToBase64String($bytes)
        return $base64.Substring(0, [Math]::Min(64, $base64.Length))
    }

    static [double] Compare([string]$Hash1, [string]$Hash2) {
        <#
        .SYNOPSIS
            Compare two CTPH hashes, return similarity score [0-100]
        .DESCRIPTION
            Uses edit distance on hash sequences, normalized to percentage
        #>

        # Parse hashes
        $parts1 = $Hash1 -split ':'
        $parts2 = $Hash2 -split ':'

        if ($parts1.Length -ne 3 -or $parts2.Length -ne 3) {
            throw "Invalid CTPH hash format"
        }

        $blockSize1 = [int]$parts1[0]
        $blockSize2 = [int]$parts2[0]

        # Block sizes must be within factor of 2
        $ratio = [Math]::Max($blockSize1, $blockSize2) / [Math]::Min($blockSize1, $blockSize2)
        if ($ratio -gt 2) {
            return 0.0
        }

        # Compare appropriate hash sequences
        $seq1 = if ($blockSize1 -eq $blockSize2) { $parts1[1] } else { $parts1[2] }
        $seq2 = if ($blockSize1 -eq $blockSize2) { $parts2[1] } else { $parts2[2] }

        # Edit distance normalized to percentage - USE rs.core.measures
        $distance = Get-LevenshteinDistance -String1 $seq1 -String2 $seq2
        $maxLen = [Math]::Max($seq1.Length, $seq2.Length)

        if ($maxLen -eq 0) {
            return 100.0
        }

        $similarity = (1.0 - ($distance / $maxLen)) * 100.0
        return [Math]::Max(0.0, $similarity)
    }
}

# ==================== MINHASH (JACCARD SIMILARITY APPROXIMATION) ====================

class MinHash {
    <#
    .SYNOPSIS
        MinHash for fast Jaccard similarity estimation
    .DESCRIPTION
        Approximates set similarity through hash signatures.
        Similar documents (high Jaccard similarity) produce similar signatures.
        Much faster than computing actual Jaccard: O(k) vs O(n)
        where k = signature size, n = set size
    #>

    static [int] $DefaultNumHashes = 128
    static [int] $DefaultShingleSize = 3

    static [uint32[]] Compute([string]$Content, [hashtable]$Options = @{}) {
        $numHashes = if ($Options.ContainsKey('NumHashes')) { $Options.NumHashes } else { [MinHash]::DefaultNumHashes }
        $shingleSize = if ($Options.ContainsKey('ShingleSize')) { $Options.ShingleSize } else { [MinHash]::DefaultShingleSize }

        # Generate shingles (n-grams)
        $shingles = [MinHash]::GenerateShingles($Content, $shingleSize)

        if ($shingles.Count -eq 0) {
            return [uint32[]]::new($numHashes)
        }

        # Initialize signature (min values)
        $signature = [uint32[]]::new($numHashes)
        for ($i = 0; $i -lt $numHashes; $i++) {
            $signature[$i] = [uint32]::MaxValue
        }

        # Generate hash functions using different seeds
        foreach ($shingle in $shingles) {
            for ($i = 0; $i -lt $numHashes; $i++) {
                $hash = [MinHash]::HashWithSeed($shingle, $i)
                $signature[$i] = [Math]::Min($signature[$i], $hash)
            }
        }

        return $signature
    }

    static [HashSet[string]] GenerateShingles([string]$Content, [int]$Size) {
        $shingles = [HashSet[string]]::new()

        # Character-level shingles
        for ($i = 0; $i -le $Content.Length - $Size; $i++) {
            $shingle = $Content.Substring($i, $Size)
            $shingles.Add($shingle) | Out-Null
        }

        return $shingles
    }

    static [uint32] HashWithSeed([string]$Value, [int]$Seed) {
        # FNV1a with seed (inline for performance - different from [FNV1a]::Compute)
        $hash = [uint32](2166136261 + $Seed)
        $prime = [uint32]16777619

        foreach ($char in $Value.ToCharArray()) {
            $hash = $hash -bxor [byte]$char
            $hash = $hash * $prime
        }

        return $hash
    }

    static [double] EstimateJaccard([uint32[]]$Sig1, [uint32[]]$Sig2) {
        <#
        .SYNOPSIS
            Estimate Jaccard similarity from MinHash signatures
        .DESCRIPTION
            Jaccard ≈ (# matching positions) / (signature length)
        #>

        if ($Sig1.Length -ne $Sig2.Length) {
            throw "Signature lengths must match"
        }

        $matches = 0
        for ($i = 0; $i -lt $Sig1.Length; $i++) {
            if ($Sig1[$i] -eq $Sig2[$i]) {
                $matches++
            }
        }

        return [double]$matches / $Sig1.Length
    }
}

# ==================== TLSH (TREND MICRO LOCALITY SENSITIVE HASH) ====================

class TLSH {
    <#
    .SYNOPSIS
        TLSH - Trend Micro Locality Sensitive Hash
    .DESCRIPTION
        Robust fuzzy hash using:
        - Sliding window (5-byte)
        - Counting Bloom filter
        - Quartile distribution
        - Checksum

        Resistant to small modifications, insertions, deletions
    #>

    static [int] $WindowSize = 5
    static [int] $BucketCount = 256

    static [string] Compute([string]$Content) {
        if ($Content.Length -lt 50) {
            Write-Warning "TLSH requires at least 50 bytes"
            return ""
        }

        # Step 1: Sliding window to populate buckets
        $buckets = [TLSH]::ComputeBuckets($Content)

        # Step 2: Compute quartiles
        $quartiles = [TLSH]::ComputeQuartiles($buckets)

        # Step 3: Build hash from bucket quartile assignments
        $body = [TLSH]::BuildBody($buckets, $quartiles)

        # Step 4: Compute checksum
        $checksum = [TLSH]::ComputeChecksum($Content)

        # Step 5: Encode length
        $lenCode = [TLSH]::EncodeLength($Content.Length)

        return "T1${checksum}${lenCode}${body}"
    }

    static [int[]] ComputeBuckets([string]$Content) {
        $buckets = [int[]]::new([TLSH]::BucketCount)

        # Sliding window - USE PearsonHash from rs.core.hash
        for ($i = 0; $i -le $Content.Length - [TLSH]::WindowSize; $i++) {
            $window = $Content.Substring($i, [TLSH]::WindowSize)
            $hash = [PearsonHash]::Compute($window)
            $buckets[$hash % [TLSH]::BucketCount]++
        }

        return $buckets
    }

    static [int[]] ComputeQuartiles([int[]]$Buckets) {
        $sorted = $Buckets | Sort-Object
        $q1 = $sorted[[int]($sorted.Length * 0.25)]
        $q2 = $sorted[[int]($sorted.Length * 0.50)]
        $q3 = $sorted[[int]($sorted.Length * 0.75)]

        return @($q1, $q2, $q3)
    }

    static [string] BuildBody([int[]]$Buckets, [int[]]$Quartiles) {
        # Encode each bucket as 2 bits based on quartile
        $bits = [Collections.BitArray]::new([TLSH]::BucketCount * 2)

        for ($i = 0; $i -lt $Buckets.Length; $i++) {
            $value = $Buckets[$i]
            $code = if ($value -le $Quartiles[0]) { 0 }
                    elseif ($value -le $Quartiles[1]) { 1 }
                    elseif ($value -le $Quartiles[2]) { 2 }
                    else { 3 }

            $bits[$i * 2] = ($code -band 1) -ne 0
            $bits[$i * 2 + 1] = ($code -band 2) -ne 0
        }

        # Convert to hex
        $bytes = [byte[]]::new(([TLSH]::BucketCount * 2) / 8)
        $bits.CopyTo($bytes, 0)

        return [Convert]::ToHexString($bytes).ToLowerInvariant()
    }

    static [string] ComputeChecksum([string]$Content) {
        # Simple byte checksum
        $sum = 0
        foreach ($char in $Content.ToCharArray()) {
            $sum += [byte]$char
        }

        return ($sum % 256).ToString("x2")
    }

    static [string] EncodeLength([int]$Length) {
        # Log scale encoding
        $code = [Math]::Min([int][Math]::Log($Length, 2), 15)
        return $code.ToString("x")
    }

    static [int] Compare([string]$Hash1, [string]$Hash2) {
        <#
        .SYNOPSIS
            Compute TLSH distance (lower = more similar)
        .DESCRIPTION
            Returns integer distance score:
            0-50: Very similar
            50-150: Somewhat similar
            >150: Different
        #>

        if (-not $Hash1.StartsWith("T1") -or -not $Hash2.StartsWith("T1")) {
            throw "Invalid TLSH format"
        }

        # Parse components
        $checksum1 = $Hash1.Substring(2, 2)
        $checksum2 = $Hash2.Substring(2, 2)
        $len1 = $Hash1.Substring(4, 1)
        $len2 = $Hash2.Substring(4, 1)
        $body1 = $Hash1.Substring(5)
        $body2 = $Hash2.Substring(5)

        # Distance components
        $lenDist = [Math]::Abs(([Convert]::ToInt32($len1, 16)) - ([Convert]::ToInt32($len2, 16)))
        $checksumDist = [Math]::Abs(([Convert]::ToInt32($checksum1, 16)) - ([Convert]::ToInt32($checksum2, 16)))

        # Hamming distance on body
        $bodyDist = 0
        $minLen = [Math]::Min($body1.Length, $body2.Length)
        for ($i = 0; $i -lt $minLen; $i++) {
            if ($body1[$i] -ne $body2[$i]) {
                $bodyDist++
            }
        }

        # Weighted combination
        return ($lenDist * 12) + ($checksumDist * 1) + ($bodyDist * 1)
    }
}

# ==================== HIGH-LEVEL FUNCTIONS ====================

function Get-SimHash {
    <#
    .SYNOPSIS
        Generate 64-bit locality-sensitive hash (SimHash)
    .DESCRIPTION
        Similar documents produce similar hashes (small Hamming distance)
    .PARAMETER Text
        Text content to hash
    .PARAMETER HashBits
        Number of bits in hash (default: 64)
    .PARAMETER RemoveStopWords
        Filter common stop words (default: true)
    .EXAMPLE
        $hash = Get-SimHash -Text $fileContent
        # Compare with Hamming distance from rs.core.measures
        $dist = Get-HammingDistance -Sig1 $hash1 -Sig2 $hash2
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Text,

        [int]$HashBits = 64,

        [bool]$RemoveStopWords = $true
    )

    process {
        $options = @{
            HashBits = $HashBits
            RemoveStopWords = $RemoveStopWords
        }

        return [SimHash]::Compute($Text, $options)
    }
}

function Get-FuzzyHash {
    <#
    .SYNOPSIS
        Generate fuzzy hash for content similarity detection
    .PARAMETER Content
        Content to hash
    .PARAMETER Algorithm
        CTPH (ssdeep-style), MinHash, SimHash, or TLSH
    .PARAMETER Options
        Algorithm-specific options
    .EXAMPLE
        # CTPH for general similarity
        $hash = Get-FuzzyHash -Content $file1 -Algorithm CTPH
        $sim = [CTPH]::Compare($hash, $hash2)

        # MinHash for set similarity (fast)
        $sig = Get-FuzzyHash -Content $file1 -Algorithm MinHash
        $jaccard = [MinHash]::EstimateJaccard($sig, $sig2)

        # SimHash for near-duplicate detection
        $hash = Get-FuzzyHash -Content $file1 -Algorithm SimHash
        $dist = Get-HammingDistance -Sig1 $hash -Sig2 $hash2

        # TLSH for robust similarity (malware analysis)
        $tlsh = Get-FuzzyHash -Content $file1 -Algorithm TLSH
        $dist = [TLSH]::Compare($tlsh, $tlsh2)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Content,

        [Parameter(Mandatory)]
        [ValidateSet('CTPH', 'MinHash', 'SimHash', 'TLSH')]
        [string]$Algorithm,

        [hashtable]$Options = @{}
    )

    process {
        switch ($Algorithm) {
            'TLSH' {
                return [TLSH]::Compute($Content)
            }
            'CTPH' {
                return [CTPH]::Compute($Content, $Options)
            }
            'SimHash' {
                return [SimHash]::Compute($Content, $Options)
            }
            'MinHash' {
                return [MinHash]::Compute($Content, $Options)
            }
        }
    }
}

function Find-SimilarContent {
    <#
    .SYNOPSIS
        Find similar content using fuzzy hashing
    .DESCRIPTION
        Searches corpus for content similar to query using specified algorithm
    .PARAMETER Query
        Content to search for
    .PARAMETER Corpus
        Array of content items to search within
    .PARAMETER Algorithm
        CTPH, MinHash, or TLSH
    .PARAMETER Threshold
        Similarity threshold (algorithm-specific)
        CTPH: 0-100 (percentage)
        MinHash: 0-1 (Jaccard estimate)
        TLSH: 0-150 (distance, lower is more similar)
    .EXAMPLE
        $similar = Find-SimilarContent `
            -Query $chatThread `
            -Corpus $allThreads `
            -Algorithm CTPH `
            -Threshold 75
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Query,

        [Parameter(Mandatory)]
        [array]$Corpus,

        [ValidateSet('CTPH', 'MinHash', 'TLSH')]
        [string]$Algorithm = 'CTPH',

        [double]$Threshold = 70
    )

    Write-Host "Computing fuzzy hash for query..." -ForegroundColor Cyan
    $queryHash = Get-FuzzyHash -Content $Query -Algorithm $Algorithm

    $results = [List[PSCustomObject]]::new()
    $i = 0

    foreach ($item in $Corpus) {
        $i++
        if ($i % 100 -eq 0) {
            Write-Progress -Activity "Searching corpus" -Status "$i / $($Corpus.Count)" -PercentComplete (($i / $Corpus.Count) * 100)
        }

        $itemHash = Get-FuzzyHash -Content $item.Content -Algorithm $Algorithm

        $score = switch ($Algorithm) {
            'CTPH' {
                [CTPH]::Compare($queryHash, $itemHash)
            }
            'MinHash' {
                [MinHash]::EstimateJaccard($queryHash, $itemHash) * 100
            }
            'TLSH' {
                100 - ([TLSH]::Compare($queryHash, $itemHash) / 2) # Normalize to 0-100
            }
        }

        if ($score -ge $Threshold) {
            $results.Add([PSCustomObject]@{
                Item = $item
                Score = [Math]::Round($score, 2)
                Algorithm = $Algorithm
            })
        }
    }

    Write-Progress -Activity "Searching corpus" -Completed
    return $results.ToArray() | Sort-Object -Property Score -Descending
}

# ==================== EXPORTS ====================

Export-ModuleMember -Function @(
    'Get-SimHash',
    'Get-FuzzyHash',
    'Find-SimilarContent'
) -Variable @('SimHash', 'CTPH', 'MinHash', 'TLSH')
