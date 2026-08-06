#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Formal test harness for rs.core.ignore.psm1 — IngestMode semantics (Design v3).

.DESCRIPTION
    Covers:
      1. Ignore mode baseline — sentinel + IgnorePatterns as one virtual root
         ignore file (negations valid in both; nested semantics; branch prune)
      2. IgnoreOverridePatterns — negations-by-convention merged into the same
         source: rescue, double-negation, and the inherited gitignore
         parent-directory constraint (+ the directory-negation recipe)
      3. Cross-mode param inertness — never errors, simply not consulted
      4. Selection mode — sentinels unconsulted, negation un-keeps, prune
         skipped, empty-leaf cleanup, fail-fast on empty/annihilated sets
      5. Output contract — regime-stamped CompiledState, old slots gone

.NOTES
    Run from any directory:
        & "$PSScriptRoot\ignore.tests.ps1"
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'

# ---------------------------------------------------------------------------
# Minimal assertion framework (house pattern)
# ---------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0

function Enter-Section ([string]$Name)
{
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
# Fixture + helper: crawl fresh per scenario (ignore mutates graph nodes)
# ---------------------------------------------------------------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-ignore-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'dist') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'sub') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'tests') -Force | Out-Null
Set-Content -Path (Join-Path $fixtureRoot '.gitignore')      -Value "*.log`n!keep.log`ndist/"
Set-Content -Path (Join-Path $fixtureRoot 'app.ps1')         -Value '$app = 1'
Set-Content -Path (Join-Path $fixtureRoot 'noise.log')       -Value 'noise'
Set-Content -Path (Join-Path $fixtureRoot 'keep.log')        -Value 'kept'
Set-Content -Path (Join-Path $fixtureRoot 'extra.tmp')       -Value 'tmp'
Set-Content -Path (Join-Path $fixtureRoot 'save.tmp')        -Value 'saved'
Set-Content -Path (Join-Path $fixtureRoot 'dist/bundle.js')  -Value 'bundle'
Set-Content -Path (Join-Path $fixtureRoot 'sub/helper.ps1')  -Value '$h = 2'
Set-Content -Path (Join-Path $fixtureRoot 'sub/note.txt')    -Value 'note'
Set-Content -Path (Join-Path $fixtureRoot 'tests/skip.ps1')  -Value '$t = 3'

Import-Module (Join-Path $v3 'rs.core.crawler.psm1') -Force
Import-Module (Join-Path $v3 'rs.core.ignore.psm1') -Force

function Invoke-IgnoreScenario ([hashtable]$CompilerArgs)
{
    $crawl = (New-FileSystemCrawler -RootPath $fixtureRoot).Invoke()
    $compiled = New-IgnoreCompiler -CrawlerGraph $crawl.Graph @CompilerArgs
    $filtered = Invoke-IgnoreFilter -CompiledNodes $compiled.CompiledNodes -CrawlerGraph $crawl.Graph
    [pscustomobject]@{
        Compiled  = $compiled
        Filtered  = $filtered
        Survivors = @($filtered.Graph.Values | ForEach-Object { $_.Files } | ForEach-Object { $_.RelativePath })
    }
}

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. Ignore mode — virtual root ignore file semantics'
    # -----------------------------------------------------------------------
    $s1 = Invoke-IgnoreScenario @{ IgnorePatterns = @('*.tmp', '!save.tmp') }
    Assert-True ($s1.Survivors -notcontains 'noise.log') 'sentinel positive: noise.log excluded'
    Assert-True ($s1.Survivors -contains 'keep.log') 'sentinel negation: keep.log rescued'
    Assert-True ($s1.Survivors -notcontains 'extra.tmp') 'IgnorePatterns positive: extra.tmp excluded'
    Assert-True ($s1.Survivors -contains 'save.tmp') 'IgnorePatterns negation: save.tmp rescued (virtual ignore file)'
    Assert-True ($s1.Survivors -notcontains 'dist/bundle.js') 'gitignored branch pruned: dist/ contents excluded'
    Assert-True ($s1.Survivors -contains 'app.ps1' -and $s1.Survivors -contains 'sub/helper.ps1') 'ordinary files kept'

    # -----------------------------------------------------------------------
    Enter-Section '2. IgnoreOverridePatterns — negations by convention'
    # -----------------------------------------------------------------------
    $s2 = Invoke-IgnoreScenario @{ IgnorePatterns = @('*.tmp'); IgnoreOverridePatterns = @('extra.tmp') }
    Assert-True ($s2.Survivors -contains 'extra.tmp') 'override countermands IgnorePatterns: extra.tmp rescued'
    Assert-True ($s2.Survivors -notcontains 'save.tmp') 'non-overridden *.tmp still excluded'

    $s2b = Invoke-IgnoreScenario @{ IgnoreOverridePatterns = @('noise.log') }
    Assert-True ($s2b.Survivors -contains 'noise.log') 'override countermands sentinel material: noise.log rescued'

    $s2c = Invoke-IgnoreScenario @{ IgnoreOverridePatterns = @('!app.ps1') }
    Assert-True ($s2c.Survivors -notcontains 'app.ps1') 'double negation → positive ignore: app.ps1 excluded (silly but admissible)'

    # Inherited gitignore semantics: file-only negation cannot re-include
    # content under an excluded directory (branch prunes first — same as git)
    $s2d = Invoke-IgnoreScenario @{ IgnoreOverridePatterns = @('dist/bundle.js') }
    Assert-True ($s2d.Survivors -notcontains 'dist/bundle.js') `
        'gitignore constraint: file-only override cannot rescue inside pruned branch'

    # The recipe: negate the directory to rescue the branch and its contents
    $s2e = Invoke-IgnoreScenario @{ IgnoreOverridePatterns = @('dist/') }
    Assert-True ($s2e.Survivors -contains 'dist/bundle.js') `
        'directory-negation recipe: override dist/ rescues branch + contents'

    # -----------------------------------------------------------------------
    Enter-Section '3. Cross-mode params are inert (never errors)'
    # -----------------------------------------------------------------------
    $s3 = Invoke-IgnoreScenario @{ SelectionPatterns = @('*.nonexistent') }   # Ignore mode (default)
    Assert-True ($s3.Survivors -contains 'app.ps1') 'Ignore mode: SelectionPatterns not consulted, no error'
    Assert-True ($s3.Survivors -notcontains 'noise.log') 'Ignore mode: sentinel semantics unaffected'

    $s3b = Invoke-IgnoreScenario @{
        IngestMode = 'Selection'; SelectionPatterns = @('*.ps1')
        IgnorePatterns = @('*.ps1'); IgnoreOverridePatterns = @('whatever')
    }
    Assert-True ($s3b.Survivors -contains 'app.ps1') `
        'Selection mode: IgnorePatterns saying ignore *.ps1 is inert — ps1 files selected anyway'

    # -----------------------------------------------------------------------
    Enter-Section '4. Selection mode'
    # -----------------------------------------------------------------------
    $s4 = Invoke-IgnoreScenario @{ IngestMode = 'Selection'; SelectionPatterns = @('*.ps1') }
    Assert-True ($s4.Survivors.Count -eq 3 -and
        ($s4.Survivors -contains 'app.ps1') -and
        ($s4.Survivors -contains 'sub/helper.ps1') -and
        ($s4.Survivors -contains 'tests/skip.ps1')) 'pure selection: exactly the three .ps1 files' "got: $($s4.Survivors -join ', ')"
    Assert-True ($s4.Filtered.Graph.Keys -notcontains 'dist/') 'empty-leaf prune: dist/ node removed (nothing selected)'
    Assert-True (@($s4.Compiled.SentinelIgnoreFiles).Count -eq 0) 'sentinel scan skipped (no I/O, no aggregate)'

    # Sentinels are not consulted: *.log selection includes the gitignored noise.log
    $s4b = Invoke-IgnoreScenario @{ IngestMode = 'Selection'; SelectionPatterns = @('*.log') }
    Assert-True ($s4b.Survivors -contains 'noise.log' -and $s4b.Survivors -contains 'keep.log') `
        'sentinels unconsulted: gitignored noise.log is selectable'

    # Negation = un-keep exception
    $s4c = Invoke-IgnoreScenario @{ IngestMode = 'Selection'; SelectionPatterns = @('*.ps1', '!tests/') }
    Assert-True ($s4c.Survivors -contains 'app.ps1' -and $s4c.Survivors -contains 'sub/helper.ps1') 'selection kept outside negation'
    Assert-True ($s4c.Survivors -notcontains 'tests/skip.ps1') 'selection negation un-keeps tests/'

    # Fail-fast: empty and self-annihilated sets throw
    $threwEmpty = $false
    try { Invoke-IgnoreScenario @{ IngestMode = 'Selection' } | Out-Null } catch { $threwEmpty = $true }
    Assert-True $threwEmpty 'fail-fast: Selection mode with no SelectionPatterns throws'

    $threwAnnih = $false
    try { Invoke-IgnoreScenario @{ IngestMode = 'Selection'; SelectionPatterns = @('*.ps1', '!*.ps1') } | Out-Null } catch { $threwAnnih = $true }
    Assert-True $threwAnnih 'fail-fast: self-annihilated selection set throws'

    # -----------------------------------------------------------------------
    Enter-Section '5. Output contract — regime-stamped CompiledState'
    # -----------------------------------------------------------------------
    $crawl5 = (New-FileSystemCrawler -RootPath $fixtureRoot).Invoke()
    $c5 = New-IgnoreCompiler -CrawlerGraph $crawl5.Graph
    $node5 = $c5.CompiledNodes | Select-Object -First 1
    Assert-True ($null -ne $node5.PSObject.Properties['CompiledState']) 'CompiledState slot present'
    Assert-True ($node5.CompiledState.Regime -eq 'Ignore') 'Regime stamped (Ignore default)'
    Assert-True ($null -eq $node5.PSObject.Properties['CompiledIgnore'] -and $null -eq $node5.PSObject.Properties['ExecutiveOverride']) `
        'old two-slot shape retired'

    $crawl5b = (New-FileSystemCrawler -RootPath $fixtureRoot).Invoke()
    $c5b = New-IgnoreCompiler -CrawlerGraph $crawl5b.Graph -IngestMode Selection -SelectionPatterns @('*.ps1')
    $node5b = $c5b.CompiledNodes | Select-Object -First 1
    Assert-True ($node5b.CompiledState.Regime -eq 'Selection') 'Regime stamped (Selection)'
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
Write-Host "`n═══ ignore.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
