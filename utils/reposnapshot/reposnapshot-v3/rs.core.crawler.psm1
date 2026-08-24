#Requires -Version 7.5

using namespace System.Collections.Generic
using namespace System.IO
using namespace System.Security

<#
.SYNOPSIS
    Crawl stage — greedy BFS over the root; produces the file-system graph.

.DESCRIPTION
    Performs an exhaustive BFS over the root directory and builds the file-system graph
    with basic metadata (size, timestamps, attributes).

    Output envelope:
      @{ RootPath; Graph; Rollups; DirectoryCount; FileCount; SkippedCount; Skipped }

    See docs/crawler-and-graph.md for design and path invariants.
#>

#region FileSystemCrawler
class FileSystemCrawler
{
    [string]   $RootPath
    [Dictionary[string, PSCustomObject]] $Graph
    [List[PSCustomObject]]               $Skipped
    [int]                                $DirectoryCount
    [int]                                $FileCount
    [bool]                               $HasRun

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

    [PSCustomObject] Invoke()
    {
        if ($this.HasRun)
        {
            throw [InvalidOperationException]::new(
                'Crawler already invoked. Create a new instance via New-FileSystemCrawler.')
        }

        $queue = [Queue[PSCustomObject]]::new()
        $rootDirPath = $this.RootPath.TrimEnd('/')

        # Seed root node
        $this.Graph[''] = $this.NewNode('', $this.RootPath, 0)
        $this.DirectoryCount = 1

        $queue.Enqueue([PSCustomObject]@{ Path = $rootDirPath; NodeDepth = 0 })

        # BFS walk
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
                        $fi = $null
                        try
                        {
                            $fi = [FileInfo]::new($entry)
                            $null = $fi.Length
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
                                Extension    = [Path]::GetExtension($entry)
                                SizeBytes    = $fi.Length
                                LastWriteUtc = $fi.LastWriteTimeUtc
                                CreationUtc  = $fi.CreationTimeUtc
                                FsAttributes = $attrs
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

    hidden [PSCustomObject] NewNode([string]$nodePath, [string]$absolutePath, [int]$depth)
    {
        return [PSCustomObject]@{
            NodePath     = $nodePath
            AbsolutePath = $absolutePath
            NodeDepth    = $depth
            Files        = [List[PSCustomObject]]::new()
        }
    }

    hidden [PSCustomObject] BuildRollups([string]$condition)
    {
        $byNode = [Dictionary[string, PSCustomObject]]::new([StringComparer]::Ordinal)
        foreach ($nodePath in $this.Graph.Keys)
        {
            $byNode[$nodePath] = [PSCustomObject]@{
                SubtreeDirCount  = 0
                SubtreeFileCount = 0
                SubtreeBytes     = 0L
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

        return [PSCustomObject]@{ Condition = $condition; ByNode = $byNode }
    }

    hidden [string] ToNodePath([string]$fwdSlashPath)
    {
        $rootTrimmed = $this.RootPath.TrimEnd('/')
        if ($fwdSlashPath -eq $rootTrimmed) { return '' }
        $rel = [Path]::GetRelativePath($rootTrimmed, $fwdSlashPath) -replace '\\', '/'
        if (-not $rel.EndsWith('/')) { $rel += '/' }
        return $rel
    }

    hidden [string] ParentNodePath([string]$nodePath)
    {
        $trimmed = $nodePath.TrimEnd('/')
        $i = $trimmed.LastIndexOf('/')
        if ($i -lt 0) { return '' }
        return $trimmed.Substring(0, $i + 1)
    }
}
#endregion

#region New-FileSystemCrawler
function New-FileSystemCrawler
{
    <#
    .SYNOPSIS
        Creates a configured FileSystemCrawler instance.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$RootPath
    )
    return [FileSystemCrawler]::new($RootPath)
}
#endregion

Export-ModuleMember -Function 'New-FileSystemCrawler'
