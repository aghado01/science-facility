using namespace System
using namespace System.IO
using namespace System.Security.Cryptography
using namespace System.Text

#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Hash algorithms for RepoSnapshot

.DESCRIPTION
    Provides FNV1a, SHA256, Pearson, and rolling hash implementations
    Optimized for file content hashing and primitive hash operations
#>

# ==================== FNV1A HASH ====================

class FNV1a {
    static [long] $Prime = 1099511628211L
    static [long] $OffsetBasis = -3750763034362895579L # 14695981039346656037 as signed

    static [long] Compute([string]$Content) {
        if ([string]::IsNullOrEmpty($Content)) {
            return [FNV1a]::OffsetBasis
        }

        $hash = [FNV1a]::OffsetBasis
        $bytes = [Encoding]::UTF8.GetBytes($Content)

        foreach ($byte in $bytes) {
            $hash = $hash -bxor $byte
            $hash = $hash * [FNV1a]::Prime
        }

        return $hash
    }

    static [string] ComputeHex([string]$Content) {
        $hash = [FNV1a]::Compute($Content)
        return [Convert]::ToString($hash, 16).PadLeft(16, '0')
    }
}

# ==================== SHA256 HASH ====================

class SHA256Hash {
    static [string] Compute([string]$Content) {
        if ([string]::IsNullOrEmpty($Content)) {
            return [string]::Empty
        }

        $bytes = [Encoding]::UTF8.GetBytes($Content)
        $sha256 = [SHA256]::Create()
        $hashBytes = $sha256.ComputeHash($bytes)
        $sha256.Dispose()

        return [Convert]::ToHexString($hashBytes).ToLowerInvariant()
    }

    static [string] ComputeFromStream([Stream]$Stream) {
        $sha256 = [SHA256]::Create()
        $hashBytes = $sha256.ComputeHash($Stream)
        $sha256.Dispose()

        return [Convert]::ToHexString($hashBytes).ToLowerInvariant()
    }
}

# ==================== PEARSON HASH ====================

class PearsonHash {
    <#
    .SYNOPSIS
        Simple Pearson hash for bucketing and indexing
    .DESCRIPTION
        Fast byte-level hash suitable for hash tables and bloom filters.
        Used by TLSH for bucket distribution.
        Not cryptographically secure - use for data structures only.
    #>

    static [byte] Compute([string]$Data) {
        if ([string]::IsNullOrEmpty($Data)) {
            return [byte]0
        }

        $hash = [byte]0
        foreach ($char in $Data.ToCharArray()) {
            $hash = ($hash -bxor [byte]$char) * 31
        }

        return $hash
    }
}

# ==================== ROLLING HASH (POLYNOMIAL) ====================

class PolynomialHash {
    static [int] $DefaultBase = 257
    static [long] $DefaultModulus = 1000000007L

    static [hashtable] GetRollContext([int]$WindowSize, [hashtable]$Options = @{}) {
        $base = if ($Options.ContainsKey('Base')) { $Options.Base } else { [PolynomialHash]::DefaultBase }
        $modulus = if ($Options.ContainsKey('Modulus')) { $Options.Modulus } else { [PolynomialHash]::DefaultModulus }

        # Precompute base^(windowSize-1) % modulus
        $basePower = 1L
        for ($i = 0; $i -lt ($WindowSize - 1); $i++) {
            $basePower = ($basePower * $base) % $modulus
        }

        return @{
            WindowSize = $WindowSize
            Base = $base
            Modulus = $modulus
            BasePower = $basePower
        }
    }

    static [long] Compute([string]$Content, [hashtable]$Context) {
        $hash = 0L
        $base = $Context.Base
        $modulus = $Context.Modulus
        $windowSize = [Math]::Min($Content.Length, $Context.WindowSize)

        for ($i = 0; $i -lt $windowSize; $i++) {
            $hash = ($hash * $base + [int]$Content[$i]) % $modulus
        }

        return $hash
    }

    static [long] RollAdd([long]$CurrentHash, [char]$OldChar, [char]$NewChar, [hashtable]$Context) {
        $base = $Context.Base
        $modulus = $Context.Modulus
        $basePower = $Context.BasePower

        # Remove oldest character: hash - oldChar * base^(n-1)
        $hash = ($CurrentHash - ([int]$OldChar * $basePower) % $modulus + $modulus) % $modulus

        # Shift and add new character: hash * base + newChar
        $hash = ($hash * $base + [int]$NewChar) % $modulus

        return $hash
    }
}

# ==================== ROLLING WINDOW MANAGER ====================

class RollingWindow {
    [long]$Hash
    [int]$WindowSize
    [Collections.Generic.Queue[char]]$Window
    [hashtable]$Context

    RollingWindow([int]$WindowSize) {
        $this.WindowSize = $WindowSize
        $this.Window = [Collections.Generic.Queue[char]]::new($WindowSize)
        $this.Context = [PolynomialHash]::GetRollContext($WindowSize)
        $this.Hash = 0L
    }

    [long] Initialize([string]$InitialContent) {
        $this.Window.Clear()
        $length = [Math]::Min($InitialContent.Length, $this.WindowSize)

        for ($i = 0; $i -lt $length; $i++) {
            $this.Window.Enqueue($InitialContent[$i])
        }

        $this.Hash = [PolynomialHash]::Compute($InitialContent, $this.Context)
        return $this.Hash
    }

    [long] Roll([char]$NewChar) {
        if ($this.Window.Count -eq $this.WindowSize) {
            $oldChar = $this.Window.Dequeue()
            $this.Hash = [PolynomialHash]::RollAdd($this.Hash, $oldChar, $NewChar, $this.Context)
        } else {
            # Window not full yet, just add
            $this.Hash = ($this.Hash * $this.Context.Base + [int]$NewChar) % $this.Context.Modulus
        }

        $this.Window.Enqueue($NewChar)
        return $this.Hash
    }

    [void] Reset() {
        $this.Window.Clear()
        $this.Hash = 0L
    }
}

# ==================== HIGH-LEVEL FUNCTIONS ====================

function Get-PathHash {
    <#
    .SYNOPSIS
        Generate SHA256 hash of file path
    .PARAMETER Path
        File path to hash
    .EXAMPLE
        $hash = Get-PathHash -Path "src/extension.ts"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Path
    )

    process {
        return [SHA256Hash]::Compute($Path)
    }
}

function Get-ContentHash {
    <#
    .SYNOPSIS
        Generate SHA256 hash of content
    .PARAMETER Content
        String content to hash
    .PARAMETER FilePath
        Path to file (reads content and hashes)
    .EXAMPLE
        $hash = Get-ContentHash -Content $fileContent
        $hash = Get-ContentHash -FilePath "src/extension.ts"
    #>
    [CmdletBinding(DefaultParameterSetName='Content')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName='Content')]
        [string]$Content,

        [Parameter(Mandatory, ParameterSetName='File')]
        [string]$FilePath
    )

    if ($PSCmdlet.ParameterSetName -eq 'File') {
        if (-not (Test-Path $FilePath)) {
            throw "File not found: $FilePath"
        }

        $stream = [FileStream]::new($FilePath, [FileMode]::Open, [FileAccess]::Read, [FileShare]::Read)
        try {
            return [SHA256Hash]::ComputeFromStream($stream)
        } finally {
            $stream.Dispose()
        }
    } else {
        return [SHA256Hash]::Compute($Content)
    }
}

function Get-RollingHash {
    <#
    .SYNOPSIS
        Compute rolling hash at every position in content
    .DESCRIPTION
        Efficient for finding repeated substrings (content-defined chunking)
    .PARAMETER Content
        String content to hash
    .PARAMETER WindowSize
        Size of rolling window (default: 64)
    .EXAMPLE
        $hashes = Get-RollingHash -Content $largeFile -WindowSize 64
        # Find repeated chunks
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [int]$WindowSize = 64
    )

    if ($Content.Length -lt $WindowSize) {
        Write-Warning "Content shorter than window size"
        return @()
    }

    $roller = [RollingWindow]::new($WindowSize)
    $hashes = [Collections.Generic.List[PSCustomObject]]::new()

    # Initialize with first window
    $initialWindow = $Content.Substring(0, $WindowSize)
    $hash = $roller.Initialize($initialWindow)
    $hashes.Add([PSCustomObject]@{
        Position = 0
        Hash = $hash
        Window = $initialWindow
    })

    # Roll through rest of content
    for ($i = $WindowSize; $i -lt $Content.Length; $i++) {
        $hash = $roller.Roll($Content[$i])
        $window = $Content.Substring($i - $WindowSize + 1, $WindowSize)
        $hashes.Add([PSCustomObject]@{
            Position = $i - $WindowSize + 1
            Hash = $hash
            Window = $window
        })
    }

    return $hashes.ToArray()
}

function Get-ContentBoundaryOffsets {
    <#
    .SYNOPSIS
        Find content-defined chunk boundaries using rolling hash
    .DESCRIPTION
        Uses Rabin fingerprinting for content-defined chunking (CDC)
        Chunks split at hash values matching pattern (e.g., divisible by threshold)
    .PARAMETER Content
        Content to chunk
    .PARAMETER WindowSize
        Rolling hash window size (default: 64)
    .PARAMETER Threshold
        Boundary trigger value (default: 4096)
        Lower = more chunks, Higher = fewer chunks
    .EXAMPLE
        $boundaries = Get-ContentBoundaryOffsets -Content $bigFile
        # Split file at natural content boundaries
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [int]$WindowSize = 64,

        [int]$Threshold = 4096
    )

    $hashes = Get-RollingHash -Content $Content -WindowSize $WindowSize
    $boundaries = [Collections.Generic.List[int]]::new()

    foreach ($entry in $hashes) {
        # Boundary condition: hash divisible by threshold
        if (($entry.Hash % $Threshold) -eq 0) {
            $boundaries.Add($entry.Position)
        }
    }

    return $boundaries.ToArray()
}

function Get-StreamHash {
    <#
    .SYNOPSIS
        One-shot hash of a stream using named algorithm (memory-efficient).
    .DESCRIPTION
        Computes hash without loading entire file into memory.
        Used by Memory for file integrity checks, content-addressable storage.
        This is a primitive function - the building block for file-based operations.
    .PARAMETER Stream
        The System.IO.Stream to hash.
    .PARAMETER Algorithm
        The hashing algorithm to use. Currently only SHA256 is supported for streaming.
    .EXAMPLE
        $stream = [System.IO.File]::OpenRead("large-file.json")
        try {
            Get-StreamHash -Stream $stream -Algorithm SHA256
        } finally {
            $stream.Dispose()
        }
    .EXAMPLE
        # Memory use case: verify file integrity
        $stream = [System.IO.File]::OpenRead($sessionFile)
        try {
            $hash = Get-StreamHash -Stream $stream
            if ($hash -eq $expectedHash) {
                Write-Host "File integrity verified"
            }
        } finally {
            $stream.Dispose()
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream,

        [Parameter()]
        [ValidateSet('SHA256')]
        [string]$Algorithm = 'SHA256'
    )

    switch ($Algorithm) {
        'SHA256' {
            return [SHA256Hash]::ComputeFromStream($Stream)
        }
        # Future: Add streaming FNV1a if needed
    }
}

function Get-BlockHashes {
    <#
    .SYNOPSIS
        Chunk content into fixed-size blocks and hash each.
    .DESCRIPTION
        Divides content into fixed blocks (e.g., 4KB) and applies non-rollable hash
        to each block. Useful for block-level deduplication, segment identity.
        This is a primitive function - provides building blocks for chunking strategies.
    .PARAMETER Content
        The string content to chunk and hash.
    .PARAMETER BlockSize
        The fixed size of each block in bytes. Default is 4096 (4KB).
    .PARAMETER Algorithm
        The hashing algorithm to use for each block.
    .OUTPUTS
        PSCustomObject with BlockIndex, Offset, Length, Hash
    .EXAMPLE
        Get-BlockHashes -Content $largeText -BlockSize 4096 -Algorithm SHA256
        # Yields: [PSCustomObject]@{ BlockIndex=0; Offset=0; Length=4096; Hash="abc..." }
    .EXAMPLE
        # Block-level deduplication
        $blocks = Get-BlockHashes -Content $fileContent -BlockSize 8192 -Algorithm FNV1a
        $uniqueBlocks = $blocks | Group-Object Hash | Where-Object Count -eq 1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Content,

        [Parameter()]
        [int]$BlockSize = 4096,

        [Parameter()]
        [ValidateSet('FNV1a', 'SHA256')]
        [string]$Algorithm = 'FNV1a'
    )

    $contentLength = $Content.Length
    $blockIndex = 0
    $offset = 0

    while ($offset -lt $contentLength) {
        $length = [Math]::Min($BlockSize, $contentLength - $offset)
        $block = $Content.Substring($offset, $length)

        $hash = switch ($Algorithm) {
            'FNV1a' { [FNV1a]::ComputeHex($block) }
            'SHA256' { [SHA256Hash]::Compute($block) }
        }

        [PSCustomObject]@{
            BlockIndex = $blockIndex
            Offset = $offset
            Length = $length
            Hash = $hash
        }

        $offset += $length
        $blockIndex++
    }
}

# ==================== EXPORTS ====================

Export-ModuleMember -Function @(
    'Get-PathHash',
    'Get-ContentHash',
    'Get-RollingHash',
    'Get-ContentBoundaryOffsets',
    'Get-StreamHash',
    'Get-BlockHashes'
) -Variable @('FNV1a', 'SHA256Hash', 'PearsonHash', 'PolynomialHash', 'RollingWindow') -Cmdlet @() -Alias @()
