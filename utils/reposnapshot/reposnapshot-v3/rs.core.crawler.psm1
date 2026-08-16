#Requires -Version 7.5

using namespace System.Collections.Generic
using namespace System.IO
using namespace System.Security


<#
.SYNOPSIS
    Crawl stage — greedy BFS over the root; produces the file-system graph.

.DESCRIPTION
    Output: @{ RootPath; Graph; DirectoryCount; FileCount; SkippedCount; Skipped }
      Graph[NodePath] → @{ NodePath; AbsolutePath; NodeDepth; Files;
                           SubtreeDirCount; SubtreeFileCount; SubtreeBytes }
      Files[]        → @{ AbsolutePath; RelativePath; NodePath; Extension;
                           SizeBytes; LastWriteUtc; CreationUtc; FsAttributes }
      Skipped[]      → @{ Path; Reason; [Error] }  — diagnostics, sibling of Graph

    Stamping rule: the crawler stamps everything that is FREE at its vantage —
    no extra syscall, no file read. Facts that cost a read (encoding, binary
    sniff, hashes) belong to later stages. Fields exist for later consumers
    even when the next stage does not use them; downstream reads, never
    re-derives. Subtree rollups are on-disk totals (pre-filter) computed from
    the graph in memory after the walk.

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

        $this.RollUp()

        $this.HasRun = $true
        return [PSCustomObject]@{
            RootPath       = $this.RootPath
            Graph          = $this.Graph
            DirectoryCount = $this.DirectoryCount
            FileCount      = $this.FileCount
            SkippedCount   = $this.Skipped.Count
            Skipped        = $this.Skipped
        }
    }

    # ── Private: NewNode — one shape for every graph node ─────────────────
    hidden [PSCustomObject] NewNode([string]$nodePath, [string]$absolutePath, [int]$depth)
    {
        return [PSCustomObject]@{
            NodePath         = $nodePath
            AbsolutePath     = $absolutePath
            NodeDepth        = $depth
            Files            = [List[PSCustomObject]]::new()
            SubtreeDirCount  = 0      # descendants, not counting self
            SubtreeFileCount = 0      # files at or below this node
            SubtreeBytes     = 0L     # sum of SizeBytes at or below this node
        }
    }

    # ── Private: RollUp — subtree totals, deepest-first so each node is
    #    complete before it is folded into its parent. In-memory only.
    hidden [void] RollUp()
    {
        foreach ($node in ($this.Graph.Values | Sort-Object -Property NodeDepth -Descending))
        {
            foreach ($f in $node.Files)
            {
                $node.SubtreeFileCount++
                $node.SubtreeBytes += $f.SizeBytes
            }
            if ($node.NodePath -eq '') { continue }

            $parent = $this.Graph[$this.ParentNodePath($node.NodePath)]
            $parent.SubtreeDirCount  += 1 + $node.SubtreeDirCount
            $parent.SubtreeFileCount += $node.SubtreeFileCount
            $parent.SubtreeBytes     += $node.SubtreeBytes
        }
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
