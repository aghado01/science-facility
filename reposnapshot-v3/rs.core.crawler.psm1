#Requires -Version 7.5

using namespace System.Collections.Generic
using namespace System.IO
using namespace System.Security


<#
.SYNOPSIS
    RepoSnapshot V3 crawler — greedy BFS walk producing the file-system graph.

.DESCRIPTION
    Output contract — each graph node carries a Files array of ItemDescriptor
    identity records (see issues/v3/rs.core.assemble-design.md):

        @{ AbsolutePath; RelativePath; NodePath; SizeBytes; LastWriteUtc }

    Path doctrine (store vs view, applied to paths):
      - AbsolutePath exists for unambiguous ingestion-side reads — it never
        appears in rendered snapshot artifacts.
      - RelativePath is the artifact-facing identity: root-anchored, forward
        slashes, no leading slash. The snapshot is anchored to a root; the
        hierarchy is represented flatly and the nested structure is encoded
        in RelativePath alone — minimal tokens for an LLM reader that needs
        repository structure, not system locations.
      - NodePath (directory portion, trailing '/'; root = '') is the graph
        key, duplicated onto file entries so descriptors remain self-standing
        after the graph is flattened for dispatch.
    All identity fields are stamped here, at walk time, from data the walk
    already holds — downstream stages filter and enrich but never re-derive
    identity (ignore is a pure filter; processors copy-on-enrich).

.TODO
    - Crawler should probably be split into multiple classes — one for the BFS walk and graph - maybe.
    - Crawler should have a separate method for getting diagnostics, rather than including that in the graph or as sidecar properties on the nodes. This keeps the graph clean and focused on representing the file system structure and metadata, while diagnostics can be a separate feed for logging, reporting, or sidecar output.
    - Pipeline can append attributes after each stage to facilitate coordination and communication from stage to stage
#>

class FileSystemCrawler
{

    # ── Configuration (immutable after construction) ──────────────────────
    [string]   $RootPath            # absolute, forward-slash, trailing /
    # Feature request: add param for max crawl depth relative to root in case the user feels like it


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
        $rootNode = [PSCustomObject]@{
            NodePath     = ''
            AbsolutePath = $this.RootPath
            NodeDepth    = 0
            Files        = [List[PSCustomObject]]::new()
        }
        $this.Graph[''] = $rootNode
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
                        $childNode = [PSCustomObject]@{
                            NodePath     = $childNodePath
                            AbsolutePath = $entry + '/'
                            NodeDepth    = $childDepth
                            Files        = [List[PSCustomObject]]::new()
                        }

                        $this.Graph[$childNodePath] = $childNode
                        $this.DirectoryCount++
                        $queue.Enqueue([PSCustomObject]@{ Path = $entry; NodeDepth = $childDepth })

                    }
                    else
                    {
                        # FILE — isolated stat read (size + last-write from one FileInfo)
                        $len = $null
                        $lastWriteUtc = [datetime]::MinValue
                        try
                        {
                            $fi = [FileInfo]::new($entry)
                            $len = $fi.Length
                            $lastWriteUtc = $fi.LastWriteTimeUtc
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

                        # Identity fields stamped at walk time — see path doctrine
                        # in the module docstring. RelativePath = NodePath + name:
                        # zero extra derivation, root-anchored by construction.
                        $this.Graph[$nodePath].Files.Add([PSCustomObject]@{
                                AbsolutePath = $entry
                                RelativePath = $nodePath + [Path]::GetFileName($entry)
                                NodePath     = $nodePath
                                SizeBytes    = $len
                                LastWriteUtc = $lastWriteUtc
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
            # custom catches for other anticipated exceptions can be added here
            # maybe binary files based on extension
            # maybe filesizeKB ceiling threshold
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
            DirectoryCount = $this.DirectoryCount
            FileCount      = $this.FileCount
            SkippedCount   = $this.Skipped.Count
            Skipped        = $this.Skipped
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

}

function New-FileSystemCrawler
{
    <#
    .SYNOPSIS
        Factory: creates a configured FileSystemCrawler instance.
    .EXAMPLE
        $result  = (New-FileSystemCrawler -RootPath 'C:\repo').Invoke()
        # $result.Graph          → Dictionary[NodePath, node]; feed to ignore compiler
        # $result.RootPath       → absolute root
        # $result.DirectoryCount / FileCount / SkippedCount / Skipped → diagnostics / _build.json
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$RootPath
    )
    return [FileSystemCrawler]::new($RootPath)
}

Export-ModuleMember -Function 'New-FileSystemCrawler'
