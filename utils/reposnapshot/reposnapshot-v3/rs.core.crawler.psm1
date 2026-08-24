#Requires -Version 7.5

using namespace System.Collections.Generic
using namespace System.IO
using namespace System.Security


<#
.SYNOPSIS
    Crawl stage — greedy BFS over the root; produces the file-system graph.

.DESCRIPTION
    Output: @{ RootPath; Graph; Rollups; DirectoryCount; FileCount;
               SkippedCount; Skipped }
      Graph[NodePath] → @{ NodePath; AbsolutePath; NodeDepth; Files }
      Files[]        → @{ AbsolutePath; RelativePath; NodePath; Extension;
                           SizeBytes; LastWriteUtc; CreationUtc; FsAttributes }
      Rollups        → @{ Scope; ByNode[NodePath] → @{ SubtreeDirCount;
                           SubtreeFileCount; SubtreeBytes } }  — a SIBLING of
                           Graph, like Skipped
      Skipped[]      → @{ Path; Reason; [Error] }  — diagnostics, sibling of Graph

    Stamping rule: the crawler stamps everything that is FREE at its vantage —
    no extra syscall, no file read. Facts that cost a read (encoding, binary
    sniff, hashes) belong to later stages. Fields exist for later consumers
    even when the next stage does not use them; downstream reads, never
    re-derives (ledger #38, measurements only).

    Rollups are METADATA ABOUT the graph, not properties OF a node (ledger
    #52). They live in their own keyed layer whose `Scope` says which set it
    aggregates — here 'walked', every file the crawl saw, before the membrane
    rejects any of it. The same aggregation over a different predicate is a
    second layer of the same shape, keyed the same way; neither can impersonate
    a current property of a node, which is what welding them onto nodes did.
    The run-level counts (DirectoryCount / FileCount) are the same aggregation
    at root scope and already sat as siblings of Graph — this makes the
    per-node case consistent with them.

    Paths: forward slashes; RelativePath root-anchored, no leading slash;
    NodePath = directory portion with trailing '/', root = ''. AbsolutePath is
    ingestion-side only — never in a payload.

    Rationale, history, deferred items:
    issues/reposnapshot/design/module-notes.md §rs.core.crawler
#>

class FileSystemCrawler
{

    # ── Configuration (immutable after construction) ──────────────────────
    [string]   $RootPath            # absolute, forward-slash, trailing /

    # ── Results (populated by Invoke) ─────────────────────────────────────
    [Dictionary[string, PSCustomObject]] $Graph
    [List[PSCustomObject]]               $Skipped
    [int]                                $DirectoryCount
    [int]                                $FileCount
    [bool]                               $HasRun

    # ── Constructor (hidden — use New-FileSystemCrawler factory) ───────────
    hidden FileSystemCrawler(
        [string]   $rootPath
    )
    {
        $resolved = [Path]::GetFullPath($rootPath) -replace '\\', '/'
        if (-not $resolved.EndsWith('/')) { $resolved += '/' }

        if (-not [Directory]::Exists($resolved))
        {
            throw [DirectoryNotFoundException]::new("Root path not found: $rootPath")
        }

        $this.RootPath = $resolved
        $this.Graph = [Dictionary[string, PSCustomObject]]::new([StringComparer]::Ordinal)
        $this.Skipped = [List[PSCustomObject]]::new()
        $this.DirectoryCount = 0
        $this.FileCount = 0
        $this.HasRun = $false
    }

    # ── Invoke — single exhaustive BFS walk ───────────────────────────────
    [PSCustomObject] Invoke()
    {
        if ($this.HasRun)
        {
            throw [InvalidOperationException]::new(
                'Crawler already invoked. Create a new instance via New-FileSystemCrawler.')
        }

        $queue = [Queue[PSCustomObject]]::new()
        $rootDirPath = $this.RootPath.TrimEnd('/')

        # ── Seed root node ──
        $this.Graph[''] = $this.NewNode('', $this.RootPath, 0)
        $this.DirectoryCount = 1

        $queue.Enqueue([PSCustomObject]@{ Path = $rootDirPath; NodeDepth = 0 })

        # ── BFS loop — each directory is its own failure domain ──
        while ($queue.Count -gt 0)
        {
            $item = $queue.Dequeue()
            $dir = $item.Path
            $nodePath = $this.ToNodePath($dir)

            try
            {
                foreach ($entryRaw in ([Directory]::EnumerateFileSystemEntries($dir) | Sort-Object))
                {
                    $entry = $entryRaw -replace '\\', '/'

                    # Attribute read isolated — one bad entry does not kill the directory
                    $attrs = $null
                    try { $attrs = [File]::GetAttributes($entry) }
                    catch
                    {
                        $this.Skipped.Add([PSCustomObject]@{
                                Path   = $entry
                                Reason = 'AttributeReadFailed'
                                Error  = $_.Exception.GetType().Name
                            })
                        continue
                    }

                    if ($attrs.HasFlag([FileAttributes]::Directory))
                    {

                        # Skip symlinks / junctions — entire subtree excluded
                        if ($attrs.HasFlag([FileAttributes]::ReparsePoint))
                        {
                            $this.Skipped.Add([PSCustomObject]@{
                                    Path   = $entry
                                    Reason = 'ReparsePoint'
                                })
                            continue
                        }

                        $childDepth = $item.NodeDepth + 1
                        $childNodePath = $this.ToNodePath($entry)
                        $this.Graph[$childNodePath] = $this.NewNode($childNodePath, $entry + '/', $childDepth)
                        $this.DirectoryCount++
                        $queue.Enqueue([PSCustomObject]@{ Path = $entry; NodeDepth = $childDepth })

                    }
                    else
                    {
                        # FILE — one FileInfo stat serves size, timestamps; attributes already in hand
                        $fi = $null
                        try
                        {
                            $fi = [FileInfo]::new($entry)
                            $null = $fi.Length   # forces the single stat; throws here if it will
                        }
                        catch
                        {
                            $this.Skipped.Add([PSCustomObject]@{
                                    Path   = $entry
                                    Reason = 'FileStatReadFailed'
                                    Error  = $_.Exception.GetType().Name
                                })
                            continue
                        }

                        $this.Graph[$nodePath].Files.Add([PSCustomObject]@{
                                AbsolutePath = $entry
                                RelativePath = $nodePath + [Path]::GetFileName($entry)
                                NodePath     = $nodePath
                                Extension    = [Path]::GetExtension($entry)   # leading '.', '' if none
                                SizeBytes    = $fi.Length
                                LastWriteUtc = $fi.LastWriteTimeUtc
                                CreationUtc  = $fi.CreationTimeUtc
                                FsAttributes = $attrs                         # [FileAttributes] flags
                            })
                        $this.FileCount++
                    }
                }
            }
            catch [UnauthorizedAccessException]
            {
                $this.Skipped.Add([PSCustomObject]@{ Path = $dir; Reason = 'AccessDenied' })
            }
            catch [PathTooLongException]
            {
                $this.Skipped.Add([PSCustomObject]@{ Path = $dir; Reason = 'PathTooLong' })
            }
            catch [IOException]
            {
                $this.Skipped.Add([PSCustomObject]@{ Path = $dir; Reason = 'IOException'; Error = $_.Exception.Message })
            }
            catch [SecurityException]
            {
                $this.Skipped.Add([PSCustomObject]@{ Path = $dir; Reason = 'SecurityException' })
            }
            catch [NotSupportedException]
            {
                $this.Skipped.Add([PSCustomObject]@{ Path = $dir; Reason = 'NotSupported' })
            }
            catch
            {
                $this.Skipped.Add([PSCustomObject]@{
                        Path   = $dir
                        Reason = $_.Exception.GetType().Name
                        Error  = $_.Exception.Message
                    })
            }
        }

        $this.HasRun = $true
        return [PSCustomObject]@{
            RootPath       = $this.RootPath
            Graph          = $this.Graph
            Rollups        = $this.BuildRollups('walked')
            DirectoryCount = $this.DirectoryCount
            FileCount      = $this.FileCount
            SkippedCount   = $this.Skipped.Count
            Skipped        = $this.Skipped
        }
    }

    # ── Private: NewNode — one shape for every graph node ─────────────────
    # Structure only. Subtree totals are metadata ABOUT the graph and live in
    # their own layer (BuildRollups, ledger #52) — a node never carries an
    # aggregate over itself.
    hidden [PSCustomObject] NewNode([string]$nodePath, [string]$absolutePath, [int]$depth)
    {
        return [PSCustomObject]@{
            NodePath     = $nodePath
            AbsolutePath = $absolutePath
            NodeDepth    = $depth
            Files        = [List[PSCustomObject]]::new()
        }
    }

    # ── Private: BuildRollups — the subtree aggregation, over one predicate ──
    # Deepest-first, so each node is complete before it folds into its parent.
    # Returns a KEYED LAYER, not node mutations: @{ Scope; ByNode }. The scope
    # is the layer's identity — run this over a different set (the surviving
    # entries, the discarded ones) and the result is another layer of the same
    # shape, keyed the same way, that cannot be mistaken for this one.
    # In-memory only; reads SizeBytes, measures nothing.
    hidden [PSCustomObject] BuildRollups([string]$scope)
    {
        $byNode = [Dictionary[string, PSCustomObject]]::new([StringComparer]::Ordinal)
        foreach ($nodePath in $this.Graph.Keys)
        {
            $byNode[$nodePath] = [PSCustomObject]@{
                SubtreeDirCount  = 0      # descendants, not counting self
                SubtreeFileCount = 0      # files at or below this node
                SubtreeBytes     = 0L     # sum of SizeBytes at or below this node
            }
        }

        foreach ($node in ($this.Graph.Values | Sort-Object -Property NodeDepth -Descending))
        {
            $r = $byNode[$node.NodePath]
            foreach ($f in $node.Files)
            {
                $r.SubtreeFileCount++
                $r.SubtreeBytes += $f.SizeBytes
            }
            if ($node.NodePath -eq '') { continue }

            $p = $byNode[$this.ParentNodePath($node.NodePath)]
            $p.SubtreeDirCount  += 1 + $r.SubtreeDirCount
            $p.SubtreeFileCount += $r.SubtreeFileCount
            $p.SubtreeBytes     += $r.SubtreeBytes
        }

        return [PSCustomObject]@{ Scope = $scope; ByNode = $byNode }
    }

    # ── Private: ToNodePath ───────────────────────────────────────────────
    # All inputs are forward-slash paths. Root → ''. Others → 'src/lib/' (trailing /).
    hidden [string] ToNodePath([string]$fwdSlashPath)
    {
        $rootTrimmed = $this.RootPath.TrimEnd('/')
        if ($fwdSlashPath -eq $rootTrimmed) { return '' }
        $rel = [Path]::GetRelativePath($rootTrimmed, $fwdSlashPath) -replace '\\', '/'
        if (-not $rel.EndsWith('/')) { $rel += '/' }
        return $rel
    }

    # ── Private: ParentNodePath — 'src/lib/' → 'src/'; 'src/' → '' ─────────
    hidden [string] ParentNodePath([string]$nodePath)
    {
        $trimmed = $nodePath.TrimEnd('/')
        $i = $trimmed.LastIndexOf('/')
        if ($i -lt 0) { return '' }
        return $trimmed.Substring(0, $i + 1)
    }

}

function New-FileSystemCrawler
{
    <#
    .SYNOPSIS
        Factory: creates a configured FileSystemCrawler instance.
    .EXAMPLE
        $result = (New-FileSystemCrawler -RootPath 'C:\repo').Invoke()
        # $result.Graph    → Dictionary[NodePath, node]; feed to the ignore stage
        # $result.Skipped  → diagnostics feed
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$RootPath
    )
    return [FileSystemCrawler]::new($RootPath)
}

Export-ModuleMember -Function 'New-FileSystemCrawler'
