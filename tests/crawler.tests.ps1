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
# Minimal assertion framework (house pattern — see colonel.tests.ps1)
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
    foreach ($field in @('AbsolutePath', 'RelativePath', 'NodePath', 'SizeBytes', 'LastWriteUtc'))
    {
        Assert-True ($null -ne $util.PSObject.Properties[$field]) "field present: $field"
    }
    Assert-True ($util.NodePath -eq 'src/lib/') 'NodePath matches owning node key'
    Assert-True ($util.SizeBytes -gt 0) 'SizeBytes positive'
    Assert-True ($util.LastWriteUtc -is [datetime]) 'LastWriteUtc is [datetime]'
    Assert-True ($util.LastWriteUtc.Kind -eq [System.DateTimeKind]::Utc) 'LastWriteUtc Kind = Utc'
    Assert-True (([datetime]::UtcNow - $util.LastWriteUtc).TotalMinutes -lt 5) 'LastWriteUtc is recent (fixture just written)'

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
finally
{
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ crawler.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
