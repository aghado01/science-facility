
using namespace System
using namespace System.IO
using namespace System.Text
using namespace System.Collections.Generic
#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Comprehensive file sharding module for RepoSnapshot (v3.1 generation)

.DESCRIPTION
    Self-contained sharding module with:
    - Partitioning strategies (Flat, ByFileType, ByRootDirectory)
    - Shard-specific I/O (JSONL/Piped readers/writers)
    - Path and timestamp utilities
    - Orchestration with proper directory conventions
    - Comprehensive utilities (manifest, validation, reverse lookup)

.NOTES
    DISPOSITION (re-dispositioned 2026-07-22 — issues/thread-corpus-container.md,
    lts-v3-transfer-audit inventory): the JSONL/Piped machinery here is NOT
    vestigial code-track output — it is the store substrate for the
    thread-corpus track. Partition-Files additionally serves the LTS shard
    path (grouping/packing) and is part of the emission-side ARRANGEMENT
    layer (rs.core.assemble-design.md).

    Writer-phase reconciliations queued:
    - Partition-Files probes a `ByteSpan` property — align to the SpanBytes
      byte-semantics naming (payload span, never on-disk size).
    - ConvertTo-ShardFiles consumes the LTS monolith JSON artifact or a
      Files array; the IR era adds an entries entry point (the monolith is
      optional output, not pipeline input — "Monolith → IR distillation").
#>

# ═══════════════════════════════════════════════════════════════════════════
# MODULE DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════

# Numeric core (identity hashing + simhash) — replaces rs.core.hash/lsh

Import-Module (Join-Path $PSScriptRoot 'rs.lts.numerics.psm1') -ErrorAction Stop


# ═══════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS (Path, Timestamp, Validation)
# ═══════════════════════════════════════════════════════════════════════════

function Get-Timestamp {
    <#
    .SYNOPSIS
        Generate standardized timestamp for file/directory naming

    .DESCRIPTION
        Returns timestamp in yyyyMMddHHmmss format for consistent naming conventions.
        Used throughout sharding for output directory and file naming.

    .PARAMETER DateTime
        Optional DateTime object. Defaults to current UTC time.

    .OUTPUTS
        String - Timestamp in format: 20251209054732

    .EXAMPLE
        $timestamp = Get-Timestamp
        # Returns: "20251209054732"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [DateTime]$DateTime = [DateTime]::UtcNow
    )

    return $DateTime.ToString("yyyyMMddHHmmss")
}

function Get-NormalizedPath {
    <#
    .SYNOPSIS
        Normalize path for consistent cross-platform handling

    .DESCRIPTION
        - Converts backslashes to forward slashes
        - Removes redundant ./ and ../
        - Trims leading/trailing slashes
        - Handles both absolute and relative paths

    .PARAMETER Path
        Path to normalize

    .OUTPUTS
        String - Normalized path

    .EXAMPLE
        Get-NormalizedPath ".\src\..\lib\file.ts"
        # Returns: "lib/file.ts"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    # Convert to forward slashes
    $normalized = $Path -replace '\\', '/'

    # Remove redundant ./
    $normalized = $normalized -replace '^\.\/+', ''

    # Collapse multiple slashes
    $normalized = $normalized -replace '/+', '/'

    # Trim leading/trailing slashes for relative paths
    if (-not [IO.Path]::IsPathRooted($normalized)) {
        $normalized = $normalized.Trim('/')
    }

    return $normalized
}

function ConvertTo-RelativePath {
    <#
    .SYNOPSIS
        Convert absolute path to relative path from a base directory

    .DESCRIPTION
        Calculates relative path from RootPath to TargetPath.
        Normalizes result with forward slashes.

    .PARAMETER TargetPath
        The path to convert (can be absolute or already relative)

    .PARAMETER RootPath
        The base directory to calculate relative from

    .OUTPUTS
        String - Relative path from RootPath to TargetPath

    .EXAMPLE
        ConvertTo-RelativePath -TargetPath "C:\Repo\src\app.ts" -RootPath "C:\Repo"
        # Returns: "src/app.ts"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,

        [Parameter(Mandatory)]
        [string]$RootPath
    )

    try {
        # Resolve to absolute paths
        $targetResolved = [IO.Path]::GetFullPath($TargetPath)
        $rootResolved = [IO.Path]::GetFullPath($RootPath)

        # Calculate relative path
        $uri = [Uri]::new($rootResolved + [IO.Path]::DirectorySeparatorChar)
        $relative = $uri.MakeRelativeUri([Uri]::new($targetResolved)).ToString()

        # Decode URI encoding and normalize
        $relative = [Uri]::UnescapeDataString($relative)
        return Get-NormalizedPath $relative
    }
    catch {
        # Fallback: simple substring if same drive
        if ($TargetPath.StartsWith($RootPath, [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $TargetPath.Substring($RootPath.Length).TrimStart('\\', '/')
            return Get-NormalizedPath $relative
        }

        # Give up, return normalized target
        return Get-NormalizedPath $TargetPath
    }
}

function Test-ValidShardDirectory {
    <#
    .SYNOPSIS
        Validate that a directory can be used for shard output

    .DESCRIPTION
        Checks that:
        - Parent directory exists (or can be created)
        - Path is valid
        - No permission issues

    .PARAMETER Path
        Directory path to validate

    .PARAMETER CreateIfMissing
        Create directory if it doesn't exist

    .OUTPUTS
        Boolean - True if valid, False otherwise
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [switch]$CreateIfMissing
    )

    try {
        if (Test-Path $Path -PathType Container) {
            return $true
        }

        if ($CreateIfMissing) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            return $true
        }

        # Check if parent exists
        $parent = Split-Path -Parent $Path
        if ($parent -and (Test-Path $parent -PathType Container)) {
            return $true
        }

        return $false
    }
    catch {
        Write-Verbose "Directory validation failed: $($_.Exception.Message)"
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# LAYER 1: PURE SHARDING LOGIC
# ═══════════════════════════════════════════════════════════════════════════

function Partition-Files {
    <#
    .SYNOPSIS
        Partition files into shards using advanced strategies

    .DESCRIPTION
        Pure partitioning logic with no I/O dependencies.

        GROUPING STRATEGIES:
        - Flat: Single pool, sorted by PathHash (even distribution)
        - ByFileType: Group by file extension (.ts, .py, .md, etc.)
        - ByRootDirectory: Group by top-level directory

        PACKING STRATEGIES:
        - Greedy: First-fit, O(n), fast
        - Balanced: Best-fit with load balancing (even shard sizes)
        - Loose: Conservative packing with 20% headroom

        OVERSIZED FILES:
        Files exceeding MaxShardSizeKB can either:
        1. Throw error (default)
        2. Get dedicated shard (with -AllowOversizedShards)

    .OUTPUTS
        PSCustomObject with:
        - Shards: Array of shard objects
        - TotalFiles: Total number of files processed
        - OversizedFiles: Count of oversized files
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [array]$Files,

        [ValidateRange(1, 100000)]
        [int]$MaxFilesPerShard = 1000,

        [ValidateRange(1, 1048576)]
        [int]$MaxShardSizeKB = 2048,

        [long]$MaxShardSpanBytes = 0,

        [ValidateSet('Flat', 'ByFileType', 'ByRootDirectory')]
        [string]$GroupingStrategy = 'Flat',

        [ValidateSet('Greedy', 'Balanced', 'Loose')]
        [string]$PackingStrategy = 'Greedy',

        [switch]$AllowOversizedShards
    )

    if ($Files.Count -eq 0) {
        Write-Verbose "No files to partition"
        return [PSCustomObject]@{
            Shards         = @()
            TotalFiles     = 0
            OversizedFiles = 0
        }
    }

    $maxSpanBytes = if ($MaxShardSpanBytes -gt 0) { $MaxShardSpanBytes } else { [long]$MaxShardSizeKB * 1024L }
    Write-Verbose "Partitioning $($Files.Count) files [Grouping: $GroupingStrategy, Packing: $PackingStrategy, MaxSpanBytes: $maxSpanBytes]"

    # Step 1: Group files by strategy
    $groups = switch ($GroupingStrategy) {
        'Flat' {
            @{
                'all' = $Files | Sort-Object { Get-PathHash $_.RelativePath }
            }
        }

        'ByFileType' {
            $grouped = [ordered]@{}
            foreach ($file in $Files) {
                $ext = [IO.Path]::GetExtension($file.RelativePath).ToLower()
                if (-not $ext) { $ext = '.noext' }

                if (-not $grouped.Contains($ext)) {
                    $grouped[$ext] = [List[object]]::new()
                }
                $grouped[$ext].Add($file)
            }

            # Sort groups by first appearance order, then preserve tree order inside each group
            foreach ($key in @($grouped.Keys)) {
                $grouped[$key] = $grouped[$key] | Sort-Object RelativePath
            }

            $grouped
        }

        'ByRootDirectory' {
            $grouped = [ordered]@{}
            foreach ($file in $Files) {
                $parts = $file.RelativePath -split '[/\\]'
                $rootDir = if ($parts.Count -gt 1) { $parts[0] } else { '.root' }

                if (-not $grouped.Contains($rootDir)) {
                    $grouped[$rootDir] = [List[object]]::new()
                }
                $grouped[$rootDir].Add($file)
            }

            # Sort within each group to preserve top-to-bottom tree order
            foreach ($key in @($grouped.Keys)) {
                $grouped[$key] = $grouped[$key] | Sort-Object RelativePath
            }

            # Ensure the virtual root group is assigned the first shard by convention.
            if ($grouped.Contains('.root')) {
                $rootGroup = $grouped['.root']
                $grouped.Remove('.root')
                $grouped.Insert(0, '.root', $rootGroup)
            }

            $grouped
        }
    }

    # Step 2: Pack files into shards based on strategy
    $shards = [List[object]]::new()
    $oversizedCount = 0

    foreach ($groupKey in $groups.Keys) {
        $groupFiles = $groups[$groupKey]

        switch ($PackingStrategy) {
            'Greedy' {
                $currentShard = [List[object]]::new()
                $currentSizeKB = 0.0

                foreach ($file in $groupFiles) {
                    $fileSizeBytes = if ($file.PSObject.Properties['ByteSpan']) {
                        [long]$file.ByteSpan
                    }
                    elseif ($file.Content) {
                        [Text.Encoding]::UTF8.GetByteCount($file.Content)
                    }
                    else { 0L }
                    $fileSizeKB = $fileSizeBytes / 1KB

                    # Handle oversized files
                    if ($fileSizeBytes -gt $maxSpanBytes) {
                        if (-not $AllowOversizedShards) {
                            throw "File exceeds MaxShardSpanBytes ($([Math]::Round($fileSizeKB, 2))KB > $([Math]::Round($maxSpanBytes / 1KB, 2))KB): $($file.RelativePath). Use -AllowOversizedShards to create dedicated shard."
                        }

                        # Flush current shard if not empty
                        if ($currentShard.Count -gt 0) {
                            $shards.Add([PSCustomObject]@{
                                    Files       = $currentShard.ToArray()
                                    SizeKB      = $currentSizeKB
                                    IsOversized = $false
                                    GroupKey    = $groupKey
                                })
                            $currentShard = [List[object]]::new()
                            $currentSizeKB = 0.0
                        }

                        # Create dedicated shard for oversized file
                        $shards.Add([PSCustomObject]@{
                                Files       = @($file)
                                SizeKB      = $fileSizeKB
                                IsOversized = $true
                                GroupKey    = $groupKey
                            })
                        $oversizedCount++
                        Write-Warning "Oversized file assigned to dedicated shard: $($file.RelativePath) ($([Math]::Round($fileSizeKB, 2))KB)"
                        continue
                    }

                    # Check if adding file would exceed limits
                    $wouldExceedSize = ($currentSizeKB + $fileSizeKB) -gt ($maxSpanBytes / 1KB)
                    $wouldExceedCount = $currentShard.Count -ge $MaxFilesPerShard

                    if ($wouldExceedSize -or $wouldExceedCount) {
                        # Flush current shard
                        if ($currentShard.Count -gt 0) {
                            $shards.Add([PSCustomObject]@{
                                    Files       = $currentShard.ToArray()
                                    SizeKB      = $currentSizeKB
                                    IsOversized = $false
                                    GroupKey    = $groupKey
                                })
                        }

                        # Start new shard
                        $currentShard = [List[object]]::new()
                        $currentSizeKB = 0.0
                    }

                    # Add file to current shard
                    $currentShard.Add($file)
                    $currentSizeKB += $fileSizeKB
                }

                # Flush remaining files
                if ($currentShard.Count -gt 0) {
                    $shards.Add([PSCustomObject]@{
                            Files       = $currentShard.ToArray()
                            SizeKB      = $currentSizeKB
                            IsOversized = $false
                            GroupKey    = $groupKey
                        })
                }
            }

            'Balanced' {
                # Calculate target shard size for even distribution
                $totalSizeBytes = ($groupFiles | ForEach-Object {
                        if ($_.PSObject.Properties['ByteSpan']) { [long]$_.ByteSpan } elseif ($_.Content) { [Text.Encoding]::UTF8.GetByteCount($_.Content) } else { 0L }
                    } | Measure-Object -Sum).Sum

                $estimatedShards = [Math]::Ceiling($totalSizeBytes / $maxSpanBytes)
                if ($estimatedShards -eq 0) { $estimatedShards = 1 }
                $targetPerShard = $totalSizeBytes / $estimatedShards

                Write-Verbose "Balanced packing: $([Math]::Round($totalSizeBytes / 1KB, 2)) KB across $estimatedShards shards (target: $([Math]::Round($targetPerShard / 1KB, 2)) KB/shard)"

                $currentShard = [List[object]]::new()
                $currentSizeKB = 0.0

                foreach ($file in $groupFiles) {
                    $fileSizeBytes = if ($file.PSObject.Properties['ByteSpan']) {
                        [long]$file.ByteSpan
                    }
                    elseif ($file.Content) {
                        [Text.Encoding]::UTF8.GetByteCount($file.Content)
                    }
                    else { 0L }
                    $fileSizeKB = $fileSizeBytes / 1KB

                    # Handle oversized files (same as greedy)
                    if ($fileSizeBytes -gt $maxSpanBytes) {
                        if (-not $AllowOversizedShards) {
                            throw "File exceeds MaxShardSpanBytes: $($file.RelativePath)"
                        }

                        if ($currentShard.Count -gt 0) {
                            $shards.Add([PSCustomObject]@{
                                    Files       = $currentShard.ToArray()
                                    SizeKB      = $currentSizeKB
                                    IsOversized = $false
                                    GroupKey    = $groupKey
                                })
                            $currentShard = [List[object]]::new()
                            $currentSizeKB = 0.0
                        }

                        $shards.Add([PSCustomObject]@{
                                Files       = @($file)
                                SizeKB      = $fileSizeKB
                                IsOversized = $true
                                GroupKey    = $groupKey
                            })
                        $oversizedCount++
                        continue
                    }

                    # Check against target size (allow some overage)
                    $wouldExceedTarget = ($currentSizeKB + $fileSizeKB) -gt (($targetPerShard / 1KB) * 1.1)
                    $wouldExceedMax = ($currentSizeKB + $fileSizeKB) -gt ($maxSpanBytes / 1KB)
                    $wouldExceedCount = $currentShard.Count -ge $MaxFilesPerShard

                    if (($wouldExceedTarget -and $currentShard.Count -gt 0) -or $wouldExceedMax -or $wouldExceedCount) {
                        $shards.Add([PSCustomObject]@{
                                Files       = $currentShard.ToArray()
                                SizeKB      = $currentSizeKB
                                IsOversized = $false
                                GroupKey    = $groupKey
                            })
                        $currentShard = [List[object]]::new()
                        $currentSizeKB = 0.0
                    }

                    $currentShard.Add($file)
                    $currentSizeKB += $fileSizeKB
                }

                if ($currentShard.Count -gt 0) {
                    $shards.Add([PSCustomObject]@{
                            Files       = $currentShard.ToArray()
                            SizeKB      = $currentSizeKB
                            IsOversized = $false
                            GroupKey    = $groupKey
                        })
                }
            }

            'Loose' {
                # Conservative packing with 80% fill rate
                $effectiveMax = $maxSpanBytes * 0.8
                $currentShard = [List[object]]::new()
                $currentSizeKB = 0.0

                foreach ($file in $groupFiles) {
                    $fileSizeBytes = if ($file.PSObject.Properties['ByteSpan']) {
                        [long]$file.ByteSpan
                    }
                    elseif ($file.Content) {
                        [Text.Encoding]::UTF8.GetByteCount($file.Content)
                    }
                    else { 0L }
                    $fileSizeKB = $fileSizeBytes / 1KB

                    if ($fileSizeBytes -gt $maxSpanBytes) {
                        if (-not $AllowOversizedShards) {
                            throw "File exceeds MaxShardSpanBytes: $($file.RelativePath)"
                        }

                        if ($currentShard.Count -gt 0) {
                            $shards.Add([PSCustomObject]@{
                                    Files       = $currentShard.ToArray()
                                    SizeKB      = $currentSizeKB
                                    IsOversized = $false
                                    GroupKey    = $groupKey
                                })
                            $currentShard = [List[object]]::new()
                            $currentSizeKB = 0.0
                        }

                        $shards.Add([PSCustomObject]@{
                                Files       = @($file)
                                SizeKB      = $fileSizeKB
                                IsOversized = $true
                                GroupKey    = $groupKey
                            })
                        $oversizedCount++
                        continue
                    }

                    # Use effective max (80% of limit)
                    $wouldExceedSize = ($currentSizeKB + $fileSizeKB) -gt ($effectiveMax / 1KB)
                    $wouldExceedCount = $currentShard.Count -ge $MaxFilesPerShard

                    if ($wouldExceedSize -or $wouldExceedCount) {
                        if ($currentShard.Count -gt 0) {
                            $shards.Add([PSCustomObject]@{
                                    Files       = $currentShard.ToArray()
                                    SizeKB      = $currentSizeKB
                                    IsOversized = $false
                                    GroupKey    = $groupKey
                                })
                        }
                        $currentShard = [List[object]]::new()
                        $currentSizeKB = 0.0
                    }

                    $currentShard.Add($file)
                    $currentSizeKB += $fileSizeKB
                }

                if ($currentShard.Count -gt 0) {
                    $shards.Add([PSCustomObject]@{
                            Files       = $currentShard.ToArray()
                            SizeKB      = $currentSizeKB
                            IsOversized = $false
                            GroupKey    = $groupKey
                        })
                }
            }
        }
    }

    Write-Verbose "Created $($shards.Count) shards ($oversizedCount oversized)"

    return [PSCustomObject]@{
        Shards         = $shards.ToArray()
        TotalFiles     = $Files.Count
        OversizedFiles = $oversizedCount
    }
}

function Build-ShardMetadata {
    <#
    .SYNOPSIS
        Generate TOC (Table of Contents) entries for shards

    .DESCRIPTION
        Creates comprehensive index entries with hashes for efficient lookups.
        Includes PathHash, ContentHash, and SimHash for various search strategies.

        FORMAT-AGNOSTIC: Returns pure data structures, no I/O.

    .OUTPUTS
        Array of TOC entries with:
        - GlobalIndex: Sequential index across all files
        - ShardName: Shard file name (without extension)
        - ShardIndex: Numeric shard identifier
        - ShardOffset: Position within shard (0-based)
        - RelativePath: Original file path
        - PathHash: SHA256 hash of path (for O(log n) lookups)
        - ContentHash: SHA256 hash of content (for deduplication)
        - SimHash: Similarity hash (for fuzzy matching)
        - SizeBytes: File size in bytes
        - IsOversized: Flag for oversized files
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]
        [array]$Shards,

        [string]$FileNamePrefix = 'shard'
    )

    $toc = [List[object]]::new()
    $globalIndex = 0
    $shardIndex = 1

    foreach ($shard in $Shards) {
        $shardName = "$FileNamePrefix$($shardIndex.ToString('D4'))"
        $offsetInShard = 0

        foreach ($file in $shard.Files) {
            # Compute hashes
            $pathHash = Get-PathHash $file.RelativePath
            $contentHash = if ($file.Content) { Get-ContentHash -Content $file.Content } else { $null }
            $simHash = if ($file.Content) { Get-SimHash -Text $file.Content } else { $null }
            $sizeBytes = if ($file.Content) { [Text.Encoding]::UTF8.GetByteCount($file.Content) } else { 0 }

            $tocEntry = [PSCustomObject]@{
                GlobalIndex  = $globalIndex
                ShardName    = $shardName
                ShardIndex   = $shardIndex
                ShardOffset  = $offsetInShard
                RelativePath = $file.RelativePath
                PathHash     = $pathHash
                ContentHash  = $contentHash
                SimHash      = $simHash
                SizeBytes    = $sizeBytes
                IsOversized  = $shard.IsOversized
            }

            # Add optional file attributes if present
            if ($file.PSObject.Properties['Language']) {
                $tocEntry | Add-Member -NotePropertyName Language -NotePropertyValue $file.Language
            }

            $toc.Add($tocEntry)
            $globalIndex++
            $offsetInShard++
        }

        $shardIndex++
    }

    Write-Verbose "Built TOC with $($toc.Count) entries across $($Shards.Count) shards"

    return $toc.ToArray()
}

# ═══════════════════════════════════════════════════════════════════════════
# LAYER 2: SHARD FORMAT I/O
# ═══════════════════════════════════════════════════════════════════════════

function Write-JSONLShard {
    <#
    .SYNOPSIS
        Write file objects to JSONL format shard

    .DESCRIPTION
        Writes array of file objects as newline-delimited JSON (JSONL).
        Each object is serialized to JSON and written as a single line.

        STREAMING: Uses StreamWriter for memory efficiency with large files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [object[]]$Files,

        [switch]$Compress
    )

    try {
        $sw = [StreamWriter]::new($OutputPath, $false, [Text.Encoding]::UTF8)

        foreach ($file in $Files) {
            $json = if ($Compress) {
                $file | ConvertTo-Json -Depth 100 -Compress
            }
            else {
                $file | ConvertTo-Json -Depth 100
            }
            $sw.WriteLine($json)
        }

        $sw.Flush()
        $sw.Close()

        Write-Verbose "Wrote $($Files.Count) objects to JSONL: $OutputPath"
    }
    catch {
        if ($sw) { $sw.Dispose() }
        Write-Error "Failed to write JSONL shard: $($_.Exception.Message)"
        throw
    }
}

function Write-PipedShard {
    <#
    .SYNOPSIS
        Write file objects to Piped format shard (ultra-compact)

    .DESCRIPTION
        Writes array of file objects as length-prefixed, pipe-delimited records.
        Format: 4-byte length|JSON bytes|4-byte length|JSON bytes|...

        ULTRA-COMPACT: Always uses compressed JSON (no line breaks).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [object[]]$Files
    )

    try {
        $fs = [FileStream]::new($OutputPath, [FileMode]::Create, [FileAccess]::Write)
        $bw = [BinaryWriter]::new($fs, [Text.Encoding]::UTF8)

        foreach ($file in $Files) {
            # Always compress for Piped format
            $json = $file | ConvertTo-Json -Depth 100 -Compress
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)

            # Write length prefix (4 bytes, little-endian)
            $bw.Write([int]$bytes.Length)

            # Write JSON bytes
            $bw.Write($bytes)

            # Write pipe delimiter
            $bw.Write([byte]'|'[0])
        }

        $bw.Flush()
        $bw.Close()
        $fs.Close()

        Write-Verbose "Wrote $($Files.Count) objects to Piped format: $OutputPath"
    }
    catch {
        if ($bw) { $bw.Dispose() }
        if ($fs) { $fs.Dispose() }
        Write-Error "Failed to write Piped shard: $($_.Exception.Message)"
        throw
    }
}

function Read-JSONLShard {
    <#
    .SYNOPSIS
        Read file objects from JSONL format shard

    .DESCRIPTION
        Reads newline-delimited JSON file and returns array of objects.
        Supports offset and count for selective reading.

    .PARAMETER Offset
        Starting line offset (0-based), default 0

    .PARAMETER Count
        Number of lines to read (-1 = all remaining), default -1
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Offset = 0,

        [int]$Count = -1
    )

    if (-not (Test-Path $Path)) {
        throw "JSONL shard not found: $Path"
    }

    try {
        $sr = [StreamReader]::new($Path, [Text.Encoding]::UTF8)
        $objects = [List[object]]::new()
        $lineNumber = 0
        $readCount = 0

        while ($null -ne ($line = $sr.ReadLine())) {
            if ($lineNumber -ge $Offset) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    $lineNumber++
                    continue
                }

                try {
                    $obj = $line | ConvertFrom-Json
                    $objects.Add($obj)
                    $readCount++

                    if ($Count -ne -1 -and $readCount -ge $Count) {
                        break
                    }
                }
                catch {
                    Write-Warning "Failed to parse line ${lineNumber}: $($_.Exception.Message)"
                }
            }
            $lineNumber++
        }

        $sr.Close()

        Write-Verbose "Read $($objects.Count) objects from JSONL: $Path [Offset: $Offset, Count: $Count]"

        return $objects.ToArray()
    }
    catch {
        if ($sr) { $sr.Dispose() }
        Write-Error "Failed to read JSONL shard: $($_.Exception.Message)"
        throw
    }
}

function Read-PipedShard {
    <#
    .SYNOPSIS
        Read file objects from Piped format shard

    .DESCRIPTION
        Reads length-prefixed pipe-delimited records.
        Format: 4-byte length|JSON bytes|4-byte length|JSON bytes|...
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Offset = 0,

        [int]$Count = -1
    )

    if (-not (Test-Path $Path)) {
        throw "Piped shard not found: $Path"
    }

    try {
        $fs = [FileStream]::new($Path, [FileMode]::Open, [FileAccess]::Read)
        $br = [BinaryReader]::new($fs, [Text.Encoding]::UTF8)
        $objects = [List[object]]::new()
        $recordNumber = 0
        $readCount = 0

        while ($fs.Position -lt $fs.Length) {
            # Read length prefix
            $length = $br.ReadInt32()

            # Read JSON bytes
            $jsonBytes = $br.ReadBytes($length)

            # Read and discard pipe delimiter
            $delimiter = $br.ReadByte()

            if ($recordNumber -ge $Offset) {
                # Parse JSON
                $json = [Text.Encoding]::UTF8.GetString($jsonBytes)
                try {
                    $obj = $json | ConvertFrom-Json
                    $objects.Add($obj)
                    $readCount++

                    if ($Count -ne -1 -and $readCount -ge $Count) {
                        break
                    }
                }
                catch {
                    Write-Warning "Failed to parse record ${recordNumber}: $($_.Exception.Message)"
                }
            }

            $recordNumber++
        }

        $br.Close()
        $fs.Close()

        Write-Verbose "Read $($objects.Count) objects from Piped: $Path [Offset: $Offset, Count: $Count]"

        return $objects.ToArray()
    }
    catch {
        if ($br) { $br.Dispose() }
        if ($fs) { $fs.Dispose() }
        Write-Error "Failed to read Piped shard: $($_.Exception.Message)"
        throw
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# LAYER 3: ORCHESTRATION
# ═══════════════════════════════════════════════════════════════════════════

function ConvertTo-ShardFiles {
    <#
    .SYNOPSIS
        Convert snapshot or file array to sharded format

    .DESCRIPTION
        Complete sharding workflow orchestration:
        1. Load files from snapshot or direct array
        2. Partition using selected strategies
        3. Generate TOC with hashes
        4. Write shards and TOC in selected format

        NO CONTENT PROCESSING: Accepts pre-processed files.
        For content normalization, use Get-RepoSnapshot first.

    .PARAMETER SnapshotPath
        Path to RepoSnapshot JSON file (parameter set: FromSnapshot)

    .PARAMETER Files
        Pre-loaded array of file objects (parameter set: FromFiles)

    .PARAMETER OutputDirectory
        Directory for shard output (REQUIRED)

    .PARAMETER ShardPrefix
        Prefix for shard filenames (default: "shard")
        Recommended: Use snapshot basename for self-documenting shards

    .OUTPUTS
        PSCustomObject with:
        - ShardFiles: Array of shard file paths
        - TOCPath: Path to TOC file
        - TotalFiles: Total files processed
        - ShardsCreated: Number of shards created
        - OversizedFiles: Count of oversized files
        - Format: Format used
    #>
    [CmdletBinding(DefaultParameterSetName = 'FromSnapshot')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'FromSnapshot')]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$SnapshotPath,

        [Parameter(Mandatory, ParameterSetName = 'FromFiles')]
        [object[]]$Files,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [string]$ShardPrefix = 'shard',

        [ValidateRange(1, 100000)]
        [int]$MaxFilesPerShard = 1000,

        [ValidateRange(1, 1048576)]
        [int]$MaxShardSizeKB = 2048,

        [ValidateSet('Flat', 'ByFileType', 'ByRootDirectory')]
        [string]$GroupingStrategy = 'Flat',

        [ValidateSet('Greedy', 'Balanced', 'Loose')]
        [string]$PackingStrategy = 'Greedy',

        [switch]$AllowOversizedShards,

        [ValidateSet('JSONL', 'Piped')]
        [string]$Format = 'JSONL',

        [switch]$Compress
    )

    $ErrorActionPreference = 'Stop'

    # Step 1: Load files from snapshot if needed
    if ($PSCmdlet.ParameterSetName -eq 'FromSnapshot') {
        Write-Verbose "Loading snapshot: $SnapshotPath"

        try {
            $snapshotContent = Get-Content -Path $SnapshotPath -Raw -Encoding UTF8
            $snapshot = $snapshotContent | ConvertFrom-Json
        }
        catch {
            throw "Failed to load snapshot: $($_.Exception.Message)"
        }

        if (-not $snapshot.files) {
            throw "Snapshot missing 'files' property"
        }

        # Transform snapshot format to internal format
        $Files = $snapshot.files | ForEach-Object {
            $fileObj = [PSCustomObject]@{
                RelativePath = $_.path
            }

            if ($_.PSObject.Properties['content']) {
                $fileObj | Add-Member -NotePropertyName Content -NotePropertyValue $_.content
            }
            if ($_.PSObject.Properties['size']) {
                $fileObj | Add-Member -NotePropertyName Size -NotePropertyValue $_.size
            }
            if ($_.PSObject.Properties['language']) {
                $fileObj | Add-Member -NotePropertyName Language -NotePropertyValue $_.language
            }
            if ($_.PSObject.Properties['isbinary']) {
                $fileObj | Add-Member -NotePropertyName IsBinary -NotePropertyValue $_.isbinary
            }

            $fileObj
        }

        Write-Verbose "Extracted $($Files.Count) files from snapshot"
    }

    # Step 2: Validate and create output directory
    if (-not (Test-ValidShardDirectory -Path $OutputDirectory -CreateIfMissing)) {
        throw "Invalid output directory: $OutputDirectory"
    }

    Write-Verbose "Output directory: $OutputDirectory"

    # Step 3: Partition files
    $partitionResult = Partition-Files `
        -Files $Files `
        -MaxFilesPerShard $MaxFilesPerShard `
        -MaxShardSizeKB $MaxShardSizeKB `
        -GroupingStrategy $GroupingStrategy `
        -PackingStrategy $PackingStrategy `
        -AllowOversizedShards:$AllowOversizedShards

    $shards = $partitionResult.Shards

    # Step 4: Build TOC metadata
    $toc = Build-ShardMetadata -Shards $shards -FileNamePrefix $ShardPrefix

    # Step 5: Determine file extensions
    $extension = switch ($Format) {
        'JSONL' { '.jsonl' }
        'Piped' { '.piped' }
    }

    # Step 6: Write shards
    $shardFiles = [List[string]]::new()
    $shardIndex = 1

    foreach ($shard in $shards) {
        $shardFileName = "$ShardPrefix$($shardIndex.ToString('D4'))$extension"
        $shardPath = Join-Path $OutputDirectory $shardFileName

        switch ($Format) {
            'JSONL' {
                Write-JSONLShard -OutputPath $shardPath -Files $shard.Files -Compress:$Compress
            }
            'Piped' {
                Write-PipedShard -OutputPath $shardPath -Files $shard.Files
            }
        }

        $shardFiles.Add($shardPath)
        $shardIndex++
    }

    Write-Verbose "Wrote $($shardFiles.Count) shard files in $Format format"

    # Step 7: Write TOC
    $tocPath = Join-Path $OutputDirectory "toc$extension"

    switch ($Format) {
        'JSONL' {
            Write-JSONLShard -OutputPath $tocPath -Files $toc -Compress:$Compress
        }
        'Piped' {
            Write-PipedShard -OutputPath $tocPath -Files $toc
        }
    }

    Write-Verbose "Wrote TOC: $tocPath"

    # Step 8: Return result
    return [PSCustomObject]@{
        ShardFiles      = $shardFiles.ToArray()
        TOCPath         = $tocPath
        TotalFiles      = $partitionResult.TotalFiles
        ShardsCreated   = $shardFiles.Count
        OversizedFiles  = $partitionResult.OversizedFiles
        Format          = $Format
        OutputDirectory = $OutputDirectory
        ShardPrefix     = $ShardPrefix
    }
}

function Export-ShardedSnapshot {
    <#
    .SYNOPSIS
        Export snapshot to properly structured shard suite

    .DESCRIPTION
        Creates complete sharded suite with proper directory conventions:

        .snapshot/
          basename-20251209054732/
            basename-20251209054732.json     (original snapshot, copied here)
            basename-20251209054732-manifest.json
            shards/
              basename-20251209054732_0001.jsonl
              basename-20251209054732_0002.jsonl
              ...
              toc.jsonl

        DIRECTORY CONVENTIONS:
        - Parent directory: .snapshot/basename-timestamp/
        - Manifest: In parent directory (not shards/)
        - Shards: In shards/ subdirectory
        - Shard prefix: Uses snapshot basename for self-documentation

    .PARAMETER SnapshotPath
        Path to RepoSnapshot JSON file

    .PARAMETER OutputDirectory
        OPTIONAL: Override output directory.
        If not specified, creates: .snapshot/basename-timestamp/shards/

    .OUTPUTS
        PSCustomObject with comprehensive result including all artifact paths
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$SnapshotPath,

        [Parameter()]
        [string]$OutputDirectory,

        [ValidateRange(1, 100000)]
        [int]$MaxFilesPerShard = 1000,

        [ValidateRange(1, 1048576)]
        [int]$MaxShardSizeKB = 2048,

        [ValidateSet('Flat', 'ByFileType', 'ByRootDirectory')]
        [string]$GroupingStrategy = 'Flat',

        [ValidateSet('Greedy', 'Balanced', 'Loose')]
        [string]$PackingStrategy = 'Greedy',

        [switch]$AllowOversizedShards,

        [ValidateSet('JSONL', 'Piped')]
        [string]$Format = 'JSONL',

        [switch]$Compress
    )

    $ErrorActionPreference = 'Stop'

    Write-Host "`n🔄 Export-ShardedSnapshot Starting..." -ForegroundColor Cyan
    Write-Host "   Snapshot: $SnapshotPath" -ForegroundColor Gray

    # Get snapshot file info
    $snapshotFile = Get-Item -LiteralPath $SnapshotPath
    $snapshotDir = $snapshotFile.DirectoryName
    $snapshotFullName = [IO.Path]::GetFileNameWithoutExtension($snapshotFile.Name)

    # Extract or parse base name and timestamp
    # Expected format: basename-20251209054732.json
    if ($snapshotFullName -match '^(.+?)-?(\d{14})$') {
        $baseName = $matches[1]
        $timestamp = $matches[2]
    }
    else {
        # No timestamp in filename, use current
        $baseName = $snapshotFullName
        $timestamp = Get-Timestamp
    }

    Write-Verbose "Base name: $baseName, Timestamp: $timestamp"

    # Determine output structure
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        # Create proper directory structure: .snapshot/basename-timestamp/
        $parentDir = Join-Path $snapshotDir "$baseName-$timestamp"
        $shardsDir = Join-Path $parentDir "shards"
    }
    else {
        # User specified output directory
        $parentDir = $OutputDirectory
        $shardsDir = Join-Path $parentDir "shards"
    }

    Write-Verbose "Parent directory: $parentDir"
    Write-Verbose "Shards directory: $shardsDir"

    # Create directories
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        Write-Verbose "Created parent directory"
    }

    if (-not (Test-Path $shardsDir)) {
        New-Item -ItemType Directory -Path $shardsDir -Force | Out-Null
        Write-Verbose "Created shards directory"
    }

    # Copy snapshot to parent directory if not already there
    $targetSnapshotPath = Join-Path $parentDir "$baseName-$timestamp.json"
    if ($snapshotFile.FullName -ne $targetSnapshotPath) {
        Copy-Item -LiteralPath $snapshotFile.FullName -Destination $targetSnapshotPath -Force
        Write-Verbose "Copied snapshot to: $targetSnapshotPath"
        $snapshotPathToUse = $targetSnapshotPath
    }
    else {
        $snapshotPathToUse = $SnapshotPath
    }

    # Use snapshot basename as shard prefix for self-documenting shards
    $shardPrefix = "$baseName-$timestamp"

    Write-Host "`n📦 Sharding files..." -ForegroundColor Cyan
    Write-Host "   Strategy: $GroupingStrategy / $PackingStrategy" -ForegroundColor Gray
    Write-Host "   Max per shard: $MaxFilesPerShard files, $MaxShardSizeKB KB" -ForegroundColor Gray

    # Shard the files
    try {
        $shardResult = ConvertTo-ShardFiles `
            -SnapshotPath $snapshotPathToUse `
            -OutputDirectory $shardsDir `
            -ShardPrefix $shardPrefix `
            -MaxFilesPerShard $MaxFilesPerShard `
            -MaxShardSizeKB $MaxShardSizeKB `
            -GroupingStrategy $GroupingStrategy `
            -PackingStrategy $PackingStrategy `
            -AllowOversizedShards:$AllowOversizedShards `
            -Format $Format `
            -Compress:$Compress
    }
    catch {
        Write-Error "Sharding failed: $($_.Exception.Message)"
        throw
    }

    Write-Host "   ✅ Created $($shardResult.ShardsCreated) shards" -ForegroundColor Green
    Write-Host "   ✅ Processed $($shardResult.TotalFiles) files" -ForegroundColor Green
    if ($shardResult.OversizedFiles -gt 0) {
        Write-Host "   ⚠️  $($shardResult.OversizedFiles) oversized files" -ForegroundColor Yellow
    }

    # Generate manifest in parent directory (NOT shards/)
    Write-Host "`n📄 Generating manifest..." -ForegroundColor Cyan

    $manifestPath = Join-Path $parentDir "$baseName-$timestamp-manifest.json"

    # Calculate total shard size
    $totalShardSize = 0
    $shardFileInfo = @()
    foreach ($shardFile in $shardResult.ShardFiles) {
        $fileInfo = Get-Item -LiteralPath $shardFile
        $totalShardSize += $fileInfo.Length
        $shardFileInfo += [PSCustomObject]@{
            name      = $fileInfo.Name
            path      = $shardFile
            sizebytes = $fileInfo.Length
            sizekb    = [Math]::Round($fileInfo.Length / 1KB, 2)
        }
    }

    $tocInfo = Get-Item -LiteralPath $shardResult.TOCPath

    $manifest = [PSCustomObject]@{
        created   = (Get-Date).ToString("o")
        generator = @{
            module            = "RepoSnapshotLTS"
            version           = "2.9.0"
            powershellversion = $PSVersionTable.PSVersion.ToString()
        }
        source    = @{
            snapshotfile   = $snapshotPathToUse
            snapshotsizemb = [Math]::Round((Get-Item $snapshotPathToUse).Length / 1MB, 2)
            basename       = $baseName
            timestamp      = $timestamp
        }
        output    = @{
            parentdirectory = $parentDir
            shardsdirectory = $shardsDir
            format          = $Format
            totalsizemb     = [Math]::Round($totalShardSize / 1MB, 2)
        }
        sharding  = @{
            totalshards      = $shardResult.ShardsCreated
            totalfiles       = $shardResult.TotalFiles
            oversizedfiles   = $shardResult.OversizedFiles
            maxfilespershard = $MaxFilesPerShard
            maxshardsizekb   = $MaxShardSizeKB
            groupingstrategy = $GroupingStrategy
            packingstrategy  = $PackingStrategy
            compressed       = $Compress.IsPresent
        }
        files     = @{
            shards = $shardFileInfo
            toc    = @{
                name      = $tocInfo.Name
                path      = $shardResult.TOCPath
                sizebytes = $tocInfo.Length
                sizekb    = [Math]::Round($tocInfo.Length / 1KB, 2)
            }
        }
    }

    try {
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8
        Write-Host "   ✅ Manifest: $manifestPath" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to create manifest file: $($_.Exception.Message)"
    }

    # Summary
    Write-Host "`n✨ Shard Suite Complete!" -ForegroundColor Green
    Write-Host "   📁 Directory: $parentDir" -ForegroundColor Cyan
    Write-Host "   📦 Shards: $($shardResult.ShardsCreated) files" -ForegroundColor Gray
    Write-Host "   📄 Files: $($shardResult.TotalFiles) total" -ForegroundColor Gray
    Write-Host "   💾 Size: $([Math]::Round($totalShardSize / 1MB, 2)) MB" -ForegroundColor Gray

    return [PSCustomObject]@{
        SnapshotPath    = $snapshotPathToUse
        ParentDirectory = $parentDir
        ShardsDirectory = $shardsDir
        ManifestPath    = $manifestPath
        ShardFiles      = $shardResult.ShardFiles
        TOCPath         = $shardResult.TOCPath
        TotalFiles      = $shardResult.TotalFiles
        ShardsCreated   = $shardResult.ShardsCreated
        OversizedFiles  = $shardResult.OversizedFiles
        TotalSizeMB     = [Math]::Round($totalShardSize / 1MB, 2)
        Format          = $Format
        ShardPrefix     = $shardPrefix
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# LAYER 4: UTILITIES
# ═══════════════════════════════════════════════════════════════════════════

function Get-ShardManifest {
    <#
    .SYNOPSIS
        Read and parse a shard manifest file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$ManifestPath
    )

    try {
        $content = Get-Content -Path $ManifestPath -Raw -Encoding UTF8
        return $content | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to read manifest: $($_.Exception.Message)"
        throw
    }
}

function Test-ShardSuite {
    <#
    .SYNOPSIS
        Validate that a shard suite is complete and consistent
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$ShardDirectory
    )

    $ErrorActionPreference = 'Stop'

    Write-Verbose "Validating shard suite: $ShardDirectory"

    # Check for manifest
    $manifestPath = Get-ChildItem -Path $ShardDirectory -Filter "*manifest.json" | Select-Object -First 1
    if (-not $manifestPath) {
        Write-Error "Manifest file not found in $ShardDirectory"
        return $false
    }

    try {
        $manifest = Get-ShardManifest -ManifestPath $manifestPath.FullName
        Write-Verbose "✅ Manifest loaded"
    }
    catch {
        Write-Error "Failed to load manifest: $($_.Exception.Message)"
        return $false
    }

    # Check TOC
    if (-not (Test-Path $manifest.files.toc.path)) {
        Write-Error "TOC not found: $($manifest.files.toc.path)"
        return $false
    }
    Write-Verbose "✅ TOC exists"

    # Check shard files
    $missingShards = @()
    foreach ($shard in $manifest.files.shards) {
        if (-not (Test-Path $shard.path)) {
            $missingShards += $shard.name
        }
    }

    if ($missingShards.Count -gt 0) {
        Write-Error "Missing shard files: $($missingShards -join ', ')"
        return $false
    }

    Write-Verbose "✅ All $($manifest.sharding.totalshards) shards exist"
    Write-Verbose "✅ Suite validation passed"

    return $true
}

function Get-FileFromShard {
    <#
    .SYNOPSIS
        Retrieve specific file from sharded suite by path

    .DESCRIPTION
        Uses TOC to locate and retrieve a file from shards.
        Supports both JSONL and Piped formats.

    .PARAMETER ShardDirectory
        Directory containing shard suite (parent or shards/ subdirectory)

    .PARAMETER RelativePath
        Relative path of file to retrieve

    .OUTPUTS
        File object if found, null if not found
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$ShardDirectory,

        [Parameter(Mandatory)]
        [string]$RelativePath,

        [string]$TOCPath
    )

    $ErrorActionPreference = 'Stop'

    # Determine actual shards directory and TOC path
    $shardsDir = if (Test-Path (Join-Path $ShardDirectory "shards")) {
        Join-Path $ShardDirectory "shards"
    }
    else {
        $ShardDirectory
    }

    if ([string]::IsNullOrWhiteSpace($TOCPath)) {
        $TOCPath = Get-ChildItem -Path $shardsDir -Filter "toc.*" | Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $TOCPath -or -not (Test-Path $TOCPath)) {
        Write-Error "TOC file not found in $shardsDir"
        return $null
    }

    # Determine format from TOC extension
    $format = switch ([IO.Path]::GetExtension($TOCPath)) {
        '.jsonl' { 'JSONL' }
        '.piped' { 'Piped' }
        default { 'JSONL' }
    }

    Write-Verbose "Reading TOC: $TOCPath (Format: $format)"

    # Read TOC
    $toc = switch ($format) {
        'JSONL' { Read-JSONLShard -Path $TOCPath }
        'Piped' { Read-PipedShard -Path $TOCPath }
    }

    # Calculate PathHash for target file
    $pathHash = Get-PathHash $RelativePath

    # Search TOC for matching entry
    $tocEntry = $toc | Where-Object { $_.PathHash -eq $pathHash -and $_.RelativePath -eq $RelativePath } | Select-Object -First 1

    if (-not $tocEntry) {
        Write-Verbose "File not found in TOC: $RelativePath"
        return $null
    }

    Write-Verbose "Found in TOC: Shard=$($tocEntry.ShardName), Offset=$($tocEntry.ShardOffset)"

    # Build shard file path
    $extension = switch ($format) {
        'JSONL' { '.jsonl' }
        'Piped' { '.piped' }
    }

    $shardPath = Join-Path $shardsDir "$($tocEntry.ShardName)$extension"

    if (-not (Test-Path $shardPath)) {
        throw "Shard file not found: $shardPath"
    }

    Write-Verbose "Reading from shard: $shardPath [Offset: $($tocEntry.ShardOffset)]"

    # Read file from shard
    try {
        $files = switch ($format) {
            'JSONL' { Read-JSONLShard -Path $shardPath -Offset $tocEntry.ShardOffset -Count 1 }
            'Piped' { Read-PipedShard -Path $shardPath -Offset $tocEntry.ShardOffset -Count 1 }
        }

        if ($files.Count -gt 0) {
            return $files[0]
        }
        else {
            Write-Warning "File not found at expected offset in shard"
            return $null
        }
    }
    catch {
        Write-Error "Failed to read from shard: $($_.Exception.Message)"
        throw
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# EXPORTS
# ═══════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    # Utilities
    'Get-Timestamp',
    'Get-NormalizedPath',
    'ConvertTo-RelativePath',
    'Test-ValidShardDirectory',

    # Core sharding
    'Partition-Files',
    'Build-ShardMetadata',

    # I/O
    'Write-JSONLShard',
    'Write-PipedShard',
    'Read-JSONLShard',
    'Read-PipedShard',

    # Orchestration
    'ConvertTo-ShardFiles',
    'Export-ShardedSnapshot',

    # Utilities
    'Get-ShardManifest',
    'Test-ShardSuite',
    'Get-FileFromShard'
)
