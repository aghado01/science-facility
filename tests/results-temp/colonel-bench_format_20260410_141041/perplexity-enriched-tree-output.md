# @PowerShell Central can i get a wrapper for my crawler in powershellcore/ps.core.reposnapshot/rs.core/crawler.psm1 and emit a document with just the directories and metadata that would be useful as a sharded reposnapshot header doc? like directory tree structure is preserved in the filepaths and can be relative to the snapshot root directory, but i want enriched metadata so its useful

Good, I have a full picture of the crawler. The key data available from `DiscoveryCrawler` after `Invoke()`:

- `$crawler.Graph` — dict keyed by `NodePath` (relative), each node has `NodePath`, `AbsolutePath`, `NodeDepth`, `IgnoreFiles`, `Files` (list of `{AbsolutePath, SizeBytes}`)
- `$crawler.GetDiagnostics()` — totals + skipped
- `$crawler.GetProjection()` — directory-only nodes sorted by depth

The wrapper needs to: run the crawler, then emit a **header doc** with directory nodes enriched with per-directory aggregated file stats (count, total bytes, extension breakdown), child/parent relationships, ignore boundary flags, and top-level snapshot metadata. JSON is the right output since it's the natural shard header format.

Here's the module:

```powershell
#Requires -Version 7.5

using namespace System.Collections.Generic
using namespace System.IO

<#
.SYNOPSIS
Wraps DiscoveryCrawler and emits an enriched directory-only header document
suitable as a reposnapshot shard header.
#>

function New-RepoSnapshotHeader {
<#
.SYNOPSIS
Crawls a repository root and emits an enriched directory-only header document.
.DESCRIPTION
Runs DiscoveryCrawler, then enriches each directory node with aggregated file
metrics, parent/child relationships, and ignore-boundary markers. Emits a
structured PSCustomObject (or JSON file) usable as a shard header doc.
.EXAMPLE
New-RepoSnapshotHeader -RootPath 'D:/repos/myproject' -OutPath './header.json'
.EXAMPLE
$doc = New-RepoSnapshotHeader -RootPath 'D:/repos/myproject'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string] $RootPath,

        [string[]] $IgnoreFileNames = @('.gitignore', '.snapignore'),
        [string[]] $IgnorePatterns = $null,
        [string[]] $ExecutiveOverrides = $null,

        # Optional: write JSON to this path. If omitted, returns the object.
        [string] $OutPath = $null,

        # Indent depth for JSON output
        [int] $JsonDepth = 10
    )

    # ── Crawl ──────────────────────────────────────────────────────────
    $crawler = New-DiscoveryCrawler `
        -RootPath $RootPath `
        -IgnoreFileNames $IgnoreFileNames `
        -IgnorePatterns $IgnorePatterns `
        -ExecutiveOverrides $ExecutiveOverrides

    $null = $crawler.Invoke()

    $graph = $crawler.Graph
    $diag = $crawler.GetDiagnostics()

    # ── Build parent→children index (NodePath strings) ────────────────
    $childIndex = [Dictionary[string, List[string]]]::new([StringComparer]::Ordinal)
    foreach ($key in $graph.Keys) { $childIndex[$key] = [List[string]]::new() }

    foreach ($key in $graph.Keys) {
        if ($key -eq '') { continue }
        $parentKey = _GetParentNodePath $key
        if ($childIndex.ContainsKey($parentKey)) {
            $childIndex[$parentKey].Add($key)
        }
    }

    # ── Enrich each directory node ────────────────────────────────────
    $snapshotRoot = ($crawler.RootPath -replace '\\','/')
    $generatedAt = [DateTimeOffset]::UtcNow.ToString('o')

    $directoryNodes = [List[PSCustomObject]]::new($graph.Count)

    foreach ($node in ($graph.Values | Sort-Object NodeDepth, NodePath)) {

        # ── Per-directory file aggregates ──
        $fileCount = $node.Files.Count
        $totalBytes = ($node.Files | Measure-Object -Property SizeBytes -Sum).Sum
        $totalBytes ??= 0

        # Extension breakdown: { ext -> { count, bytes } }
        $extMap = [Dictionary[string, PSCustomObject]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $node.Files) {
            $ext = [Path]::GetExtension($f.AbsolutePath)
            if ([string]::IsNullOrEmpty($ext)) { $ext = '(none)' }
            if (-not $extMap.ContainsKey($ext)) {
                $extMap[$ext] = [PSCustomObject]@{ Count = 0; Bytes = 0L }
            }
            $extMap[$ext].Count++
            $extMap[$ext].Bytes += $f.SizeBytes
        }

        # ── Ignore-boundary: does this dir introduce any new ignore globs? ──
        $localIgnoreSources = @(
            $node.IgnoreFiles |
            Where-Object { $_.Source -ne 'IgnorePatterns' -and $_.Globs.Count -gt 0 } |
            ForEach-Object { $_.Source }
        )
        $isIgnoreBoundary = $localIgnoreSources.Count -gt 0

        # ── Children + parent ──
        $children = @($childIndex[$node.NodePath] | Sort-Object)
        $parentKey = if ($node.NodeDepth -eq 0) { $null } else { _GetParentNodePath $node.NodePath }

        # ── Relative path (clean, no leading slash) ──
        $relPath = if ($node.NodePath -eq '') { '.' } else { $node.NodePath.TrimEnd('/') }

        $enriched = [PSCustomObject]@{
            # Identity
            RelPath = $relPath
            NodePath = $node.NodePath
            NodeDepth = $node.NodeDepth

            # Hierarchy
            Parent = $parentKey
            Children = $children
            ChildCount = $children.Count

            # File aggregates (direct children only, not recursive)
            DirectFileCount = $fileCount
            DirectBytes = $totalBytes
            ExtBreakdown = $extMap # Dictionary<ext, {Count,Bytes}>

            # Ignore info
            IsIgnoreBoundary = $isIgnoreBoundary
            IgnoreSources = $localIgnoreSources

            # Timestamps from filesystem
            LastWriteUtc = try {
                [Directory]::GetLastWriteTimeUtc($node.AbsolutePath).ToString('o')
            } catch { $null }
            CreationUtc = try {
                [Directory]::GetCreationTimeUtc($node.AbsolutePath).ToString('o')
            } catch { $null }
        }

        # Root node gets ExecutiveOverrides surfaced
        if ($node.NodeDepth -eq 0 -and $null -ne $node.ExecutiveOverrides) {
            $enriched | Add-Member -NotePropertyName 'ExecutiveOverrides' `
                                   -NotePropertyValue $node.ExecutiveOverrides.Globs
        }

        $directoryNodes.Add($enriched)
    }

    # ── Assemble top-level header doc ─────────────────────────────────
    $headerDoc = [PSCustomObject]@{
        SchemaVersion = '1.0'
        DocumentKind = 'RepoSnapshotHeader'
        GeneratedAtUtc = $generatedAt
        SnapshotRoot = $snapshotRoot

        # Totals
        TotalDirectories = $diag.DirectoryCount
        TotalFiles = $diag.FileCount
        SkippedCount = $diag.SkippedCount

        # Crawler config echoed for reproducibility
        CrawlerConfig = [PSCustomObject]@{
            IgnoreFileNames = $IgnoreFileNames
            IgnorePatterns = $IgnorePatterns
            ExecutiveOverrides = $ExecutiveOverrides
        }

        # Skipped entries — useful for shard consumers to know what's absent
        Skipped = @($diag.Skipped)

        # The directory tree — sorted depth-first by NodeDepth then RelPath
        Directories = @($directoryNodes)
    }

    # ── Emit ──────────────────────────────────────────────────────────
    if ($OutPath) {
        $headerDoc | ConvertTo-Json -Depth $JsonDepth |
            Set-Content -Path $OutPath -Encoding UTF8 -Force
        Write-Verbose "Header doc written to: $OutPath"
    }

    return $headerDoc
}

# ── Private helper ─────────────────────────────────────────────────────
# Returns the parent NodePath of a non-root NodePath like 'src/lib/'.
# 'src/lib/' → 'src/' | 'src/' → ''
function _GetParentNodePath([string]$nodePath) {
    $trimmed = $nodePath.TrimEnd('/') # 'src/lib'
    $lastSlash = $trimmed.LastIndexOf('/')
    if ($lastSlash -le 0) { return '' } # direct child of root
    return $trimmed.Substring(0, $lastSlash) + '/'
}

Export-ModuleMember -Function 'New-RepoSnapshotHeader'
```

---

## Design Decisions

**What's enriched per directory node vs what's deliberately omitted:**

| Field | Rationale |
| :----------------------------------- | :------------------------------------------------------------------------------------------------------------------------ |
| `RelPath` | Human-readable path relative to snapshot root, `'.'` for root |
| `Parent` / `Children` / `ChildCount` | Explicit tree linkage so consumers don't need to infer from path strings |
| `DirectFileCount` / `DirectBytes` | Immediate children only — recursive rollups belong in a separate aggregation pass so the header stays flat and composable |
| `ExtBreakdown` | Per-extension `{Count, Bytes}` — useful for shard routing (e.g. skip `.log`-heavy dirs) |
| `IsIgnoreBoundary` / `IgnoreSources` | Flags dirs that introduce new ignore scope; critical for shard consumers to know filtering lineage |
| `LastWriteUtc` / `CreationUtc` | Filesystem timestamps; useful for incremental re-snapshot detection |
| `ExecutiveOverrides` | Root only, echoed from crawler so the header is self-describing |
| `CrawlerConfig` | Full config echo so a shard header is reproducible without out-of-band context |
| `Skipped` | Shard consumers need to know what's absent and why |

**Recursive byte/file rollups are not included** at the directory level intentionally — those require a bottom-up tree reduction pass and are more natural as a separate aggregation layer once shard boundaries are known. The flat per-directory aggregates here are sufficient for routing decisions.