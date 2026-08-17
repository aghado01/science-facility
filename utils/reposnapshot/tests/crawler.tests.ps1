#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Formal test harness for rs.core.crawler.psm1.

.DESCRIPTION
    Covers:
      1. Module import and factory availability
      2. Graph shape — root node, node keys, depth, trailing-slash convention
      3. File-entry ItemDescriptor identity contract:
         AbsolutePath / RelativePath / NodePath / SizeBytes / LastWriteUtc
      4. Path doctrine invariants — RelativePath root-anchored, forward
         slashes, no leading slash, NodePath derivable as its directory part
      5. Diagnostics — reparse points and stat failures land in Skipped,
         single-invoke guard throws on second Invoke()

    Fixture: a temp directory tree created per run and removed afterwards.

.NOTES
    Run from any directory:
        & "$PSScriptRoot\crawler.tests.ps1"
#>

$crawlerPath = Join-Path $PSScriptRoot '..\reposnapshot-v3\rs.core.crawler.psm1'

# ---------------------------------------------------------------------------
# Minimal assertion framework (house pattern — see colonel-dispatch.tests.ps1)
# ---------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0
$script:Section = ''

function Enter-Section ([string]$Name)
{
    $script:Section = $Name
    Write-Host "`n── $Name" -ForegroundColor Cyan
}

function Assert-True ([bool]$Condition, [string]$Label, [string]$Detail = '')
{
    if ($Condition)
    {
        $script:Passed++
        Write-Host "    PASS  $Label" -ForegroundColor Green
    }
    else
    {
        $script:Failed++
        $msg = "    FAIL  $Label"
        if ($Detail) { $msg += "  ($Detail)" }
        Write-Host $msg -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-crawler-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'src/lib') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs') -Force | Out-Null
Set-Content -Path (Join-Path $fixtureRoot 'readme.md')        -Value 'root file'
Set-Content -Path (Join-Path $fixtureRoot 'src/main.ps1')     -Value 'main'
Set-Content -Path (Join-Path $fixtureRoot 'src/lib/util.ps1') -Value 'util body'
Set-Content -Path (Join-Path $fixtureRoot 'docs/notes.txt')   -Value 'notes'

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. Module import'
    # -----------------------------------------------------------------------
    Import-Module $crawlerPath -Force
    Assert-True ($null -ne (Get-Command New-FileSystemCrawler -ErrorAction SilentlyContinue)) `
        'New-FileSystemCrawler exported'

    $result = (New-FileSystemCrawler -RootPath $fixtureRoot).Invoke()

    # -----------------------------------------------------------------------
    Enter-Section '2. Graph shape'
    # -----------------------------------------------------------------------
    Assert-True ($result.Graph.ContainsKey('')) 'root node keyed by empty string'
    Assert-True ($result.Graph.ContainsKey('src/'))      'src/ node present (trailing slash)'
    Assert-True ($result.Graph.ContainsKey('src/lib/'))  'src/lib/ node present'
    Assert-True ($result.Graph.ContainsKey('docs/'))     'docs/ node present'
    Assert-True ($result.DirectoryCount -eq 4) 'DirectoryCount = 4 (root + 3)' "got $($result.DirectoryCount)"
    Assert-True ($result.FileCount -eq 4) 'FileCount = 4' "got $($result.FileCount)"
    Assert-True ($result.Graph['src/lib/'].NodeDepth -eq 2) 'src/lib/ NodeDepth = 2'

    # -----------------------------------------------------------------------
    Enter-Section '3. File-entry identity contract (ItemDescriptor fields)'
    # -----------------------------------------------------------------------
    $util = $result.Graph['src/lib/'].Files | Where-Object { $_.RelativePath -eq 'src/lib/util.ps1' }
    Assert-True ($null -ne $util) 'util.ps1 found by RelativePath'
    foreach ($field in @('AbsolutePath', 'RelativePath', 'NodePath', 'Extension', 'SizeBytes', 'LastWriteUtc', 'CreationUtc', 'FsAttributes'))
    {
        Assert-True ($null -ne $util.PSObject.Properties[$field]) "field present: $field"
    }
    Assert-True ($util.NodePath -eq 'src/lib/') 'NodePath matches owning node key'
    Assert-True ($util.SizeBytes -gt 0) 'SizeBytes positive'
    Assert-True ($util.LastWriteUtc -is [datetime]) 'LastWriteUtc is [datetime]'
    Assert-True ($util.LastWriteUtc.Kind -eq [System.DateTimeKind]::Utc) 'LastWriteUtc Kind = Utc'
    Assert-True (([datetime]::UtcNow - $util.LastWriteUtc).TotalMinutes -lt 5) 'LastWriteUtc is recent (fixture just written)'

    # -----------------------------------------------------------------------
    Enter-Section '3b. Free-at-vantage fields (Extension / CreationUtc / FsAttributes)'
    # -----------------------------------------------------------------------
    Assert-True ($util.Extension -eq '.ps1') 'Extension carries the leading dot' "got '$($util.Extension)'"
    Assert-True ($util.Extension -eq [IO.Path]::GetExtension($util.AbsolutePath)) 'Extension agrees with [Path]::GetExtension (what ignore derives)'
    Assert-True ($util.CreationUtc -is [datetime] -and $util.CreationUtc.Kind -eq [System.DateTimeKind]::Utc) 'CreationUtc is a Utc [datetime]'
    Assert-True ($util.FsAttributes -is [IO.FileAttributes]) 'FsAttributes is a [FileAttributes] enum'
    Assert-True (-not $util.FsAttributes.HasFlag([IO.FileAttributes]::Directory)) 'FsAttributes on a file lacks Directory flag'
    Assert-True ($null -eq $util.PSObject.Properties['Attributes']) 'no bare Attributes field (crawler stamps FsAttributes; the enrichment element is ContentMeta)'
    Assert-True ($null -eq $util.PSObject.Properties['ContentMeta']) 'no ContentMeta field (name reserved for the rs-content_meta element)'

    # -----------------------------------------------------------------------
    Enter-Section '3d. Output conforms to schema/crawler.contract.json (out.file / out.node, exactly)'
    # -----------------------------------------------------------------------
    $schemaPath = Join-Path (Split-Path $crawlerPath -Parent) 'schema/crawler.contract.json'
    Assert-True (Test-Path $schemaPath) 'schema/crawler.contract.json exists'
    $contract = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($contract.stage -eq 'crawler') 'contract names its stage'
    $fileFields = @($contract.out.file.Keys)
    $stamped = @($util.PSObject.Properties.Name)
    $missing = @($fileFields | Where-Object { $_ -notin $stamped })
    $undeclared = @($stamped | Where-Object { $_ -notin $fileFields })
    Assert-True ($missing.Count -eq 0) 'every out.file field is stamped on the descriptor' "missing: $($missing -join ', ')"
    Assert-True ($undeclared.Count -eq 0) 'no stamped descriptor field is undeclared in out.file' "undeclared: $($undeclared -join ', ')"
    $nodeFields = @($contract.out.node.Keys)
    $nodeStamped = @($result.Graph['src/'].PSObject.Properties.Name)
    Assert-True (@($nodeFields | Where-Object { $_ -notin $nodeStamped }).Count -eq 0 -and @($nodeStamped | Where-Object { $_ -notin $nodeFields }).Count -eq 0) `
        'node shape equals out.node exactly' "node: $($nodeStamped -join ','); contract: $($nodeFields -join ',')"
    $resultFields = @($contract.out.result.Keys)
    $resultStamped = @($result.PSObject.Properties.Name)
    Assert-True (@($resultFields | Where-Object { $_ -notin $resultStamped }).Count -eq 0 -and @($resultStamped | Where-Object { $_ -notin $resultFields }).Count -eq 0) `
        'result envelope equals out.result exactly'

    # -----------------------------------------------------------------------
    Enter-Section '3c. Node rollups (on-disk subtree totals)'
    # -----------------------------------------------------------------------
    $root = $result.Graph['']
    $src = $result.Graph['src/']
    $lib = $result.Graph['src/lib/']
    $docs = $result.Graph['docs/']
    foreach ($field in @('SubtreeDirCount', 'SubtreeFileCount', 'SubtreeBytes'))
    {
        Assert-True ($null -ne $root.PSObject.Properties[$field]) "node field present: $field"
    }
    Assert-True ($lib.SubtreeDirCount -eq 0 -and $lib.SubtreeFileCount -eq 1) 'leaf src/lib/: 0 dirs, 1 file' "got $($lib.SubtreeDirCount)/$($lib.SubtreeFileCount)"
    Assert-True ($src.SubtreeDirCount -eq 1 -and $src.SubtreeFileCount -eq 2) 'src/: 1 dir (lib), 2 files (main + util)' "got $($src.SubtreeDirCount)/$($src.SubtreeFileCount)"
    Assert-True ($docs.SubtreeDirCount -eq 0 -and $docs.SubtreeFileCount -eq 1) 'docs/: 0 dirs, 1 file'
    Assert-True ($root.SubtreeDirCount -eq 3 -and $root.SubtreeFileCount -eq 4) 'root: 3 dirs, 4 files (= DirectoryCount-1 / FileCount)' "got $($root.SubtreeDirCount)/$($root.SubtreeFileCount)"
    $allBytes = ($result.Graph.Values | ForEach-Object { $_.Files } | Measure-Object -Property SizeBytes -Sum).Sum
    Assert-True ($root.SubtreeBytes -eq $allBytes) 'root SubtreeBytes = sum of every file SizeBytes' "got $($root.SubtreeBytes) vs $allBytes"
    Assert-True ($src.SubtreeBytes -eq ($src.Files[0].SizeBytes + $lib.SubtreeBytes)) 'src/ SubtreeBytes = own files + lib subtree'
    Assert-True ($root.SubtreeBytes -is [long]) 'SubtreeBytes stays [long]'

    # -----------------------------------------------------------------------
    Enter-Section '4. Path doctrine invariants'
    # -----------------------------------------------------------------------
    $allFiles = @($result.Graph.Values | ForEach-Object { $_.Files })
    Assert-True ($allFiles.Count -eq 4) 'flattened file total = 4'
    Assert-True (@($allFiles | Where-Object { $_.RelativePath -match '\\' }).Count -eq 0) `
        'no backslashes in any RelativePath'
    Assert-True (@($allFiles | Where-Object { $_.RelativePath.StartsWith('/') }).Count -eq 0) `
        'no leading slash on any RelativePath'
    Assert-True (@($allFiles | Where-Object { -not $_.AbsolutePath.StartsWith($result.RootPath) }).Count -eq 0) `
        'every AbsolutePath is under RootPath'
    $derivable = @($allFiles | Where-Object {
            $slash = $_.RelativePath.LastIndexOf('/')
            $dir = if ($slash -lt 0) { '' } else { $_.RelativePath.Substring(0, $slash + 1) }
            $dir -ne $_.NodePath
        })
    Assert-True ($derivable.Count -eq 0) 'NodePath = directory portion of RelativePath (derivable, deduplicated)'
    $rootFile = $result.Graph[''].Files | Where-Object { $_.RelativePath -eq 'readme.md' }
    Assert-True ($null -ne $rootFile -and $rootFile.NodePath -eq '') 'root-level file: RelativePath bare name, NodePath empty'

    # -----------------------------------------------------------------------
    Enter-Section '5. Guards and diagnostics'
    # -----------------------------------------------------------------------
    $threw = $false
    try { (New-FileSystemCrawler -RootPath $fixtureRoot) | ForEach-Object { $_.Invoke() | Out-Null; $_.Invoke() } }
    catch { $threw = $true }
    Assert-True $threw 'second Invoke() on same instance throws'
    Assert-True ($null -ne $result.PSObject.Properties['Skipped']) 'Skipped diagnostics present on result'
}
catch
{
    # A terminating error inside the try block — a StrictMode property access, a
    # parameter-binding failure — would otherwise abort the suite SILENTLY:
    # finally runs, execution resumes after the block, and the summary prints a
    # PASSING count while the remaining asserts never ran. That mode is invisible
    # from outside (tests/run-all.ps1 cannot detect it — the counts are
    # self-consistent), so it has to be caught HERE.
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}
finally
{
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ crawler.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
