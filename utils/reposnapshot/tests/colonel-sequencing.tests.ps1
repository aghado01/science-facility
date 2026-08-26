#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Sequence-manifest resolution tests for rs.core.colonel.v2 (enable → route → sort).

.DESCRIPTION
    Covers the four resolvers that turn processors/sequencing.json into a plan family:
      1. Import-SequenceManifest loads the shipped manifest and normalizes it
      2. Declared conventions are enforced, each as a terminating error
      3. Resolve-EnabledSet treats IncludeProcessors as a set and closes Requires
      4. Resolve-Classes finds only the classes the corpus contains
      5. Resolve-Variants emits dense per-class chains ordered by (Group, Rank)
      6. Processors key order is incidental; Group and Rank are authoritative

.NOTES
    Run from any directory:
        & "$PSScriptRoot\colonel-sequencing.tests.ps1"
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'
Import-Module (Join-Path $v3 'rs.core.colonel.v2.psm1') -Force -WarningAction SilentlyContinue

# ---------------------------------------------------------------------------
# Minimal assertion framework (house pattern — see colonel-dispatch.tests.ps1)
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

function Assert-Throws ([scriptblock]$Action, [string]$Label, [string]$Match)
{
    try
    {
        & $Action | Out-Null
        Assert-True $false $Label 'no error was thrown'
    }
    catch
    {
        if ($_.Exception.Message -match $Match) { Assert-True $true $Label }
        else { Assert-True $false $Label "message did not match /$Match/: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
$procDir = Join-Path $v3 'processors'
$manifest = @{}
foreach ($f in Get-ChildItem -LiteralPath $procDir -Filter '*.ps1' -File)
{
    if ($f.Name -in 'chain-executor.ps1', 'bag-helpers.ps1') { continue }
    $manifest[[IO.Path]::GetFileNameWithoutExtension($f.Name)] = $f.FullName
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-seq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null

function New-BaseDoc
{
    return [ordered]@{
        Processors = [ordered]@{
            'file-read'       = [ordered]@{ Group = '1'; Rank = '0'; Default = $true; Requires = @() }
            '$strip'          = [ordered]@{ Group = '2'; Rank = '0'; Default = $false; Requires = @('file-read') }
            'rs-indent'       = [ordered]@{ Group = '3'; Rank = '1'; Default = $false; Requires = @('file-read') }
            'rs-whitespace'   = [ordered]@{ Group = '3'; Rank = '2'; Default = $false; Requires = @('file-read') }
            'rs-content_meta' = [ordered]@{ Group = '4'; Rank = '0'; Default = $false; Requires = @('file-read') }
        }
        Routing    = [ordered]@{
            '$strip' = [ordered]@{
                powershell = [ordered]@{ extensions = @('ps1', 'psm1', 'psd1'); processor = 'rs.ps.strip' }
                csharp     = [ordered]@{ extensions = @('cs', 'csx'); processor = 'rs.cs.strip' }
            }
        }
    }
}

function New-SeqFile ($Doc)
{
    $path = Join-Path $fixtureRoot "seq-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
    ($Doc | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Import-Fixture ($Doc)
{
    return Import-SequenceManifest -Path (New-SeqFile $Doc) -Manifest $manifest
}

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. The shipped manifest loads and normalizes'
    # -----------------------------------------------------------------------
    $shipped = Import-SequenceManifest -Path (Join-Path $procDir 'sequencing.json') -Manifest $manifest

    Assert-True ($shipped.Processors.Count -eq 5) 'five sequence entries' "got $($shipped.Processors.Count)"
    Assert-True ($shipped.Processors['$strip'].IsToken) 'dollar-prefixed key is a token'
    Assert-True (-not $shipped.Processors['rs-indent'].IsToken) 'bare key is not a token'
    Assert-True ($shipped.Processors['file-read'].Default) 'file-read is Default'
    Assert-True ($shipped.Processors['rs-indent'].Group -is [int]) 'Group is an integer, not a string'
    Assert-True ($shipped.Processors['rs-whitespace'].Rank -eq 2) 'Rank parsed as 2'
    Assert-True ($shipped.ExtensionMap['.ps1'] -eq 'powershell') 'extension normalized to leading dot'
    Assert-True ($shipped.ExtensionMap['.csx'] -eq 'csharp') 'csharp extensions mapped'
    Assert-True ($shipped.Routing['$strip']['powershell'].Key -eq 'rs.ps.strip') 'route bound to processor key'

    # -----------------------------------------------------------------------
    Enter-Section '2. Declared conventions are enforced'
    # -----------------------------------------------------------------------
    Assert-Throws { Import-SequenceManifest -Path (Join-Path $fixtureRoot 'absent.json') -Manifest $manifest } `
        'missing file is a terminating error' 'not found'

    $badJson = Join-Path $fixtureRoot 'bad.json'
    Set-Content -LiteralPath $badJson -Value '{ "Processors": ' -Encoding utf8
    Assert-Throws { Import-SequenceManifest -Path $badJson -Manifest $manifest } `
        'malformed JSON is a terminating error' 'not valid JSON'

    $d = New-BaseDoc
    $d.Processors['rs-indent'].Group = 'three'
    Assert-Throws { Import-Fixture $d } 'non-integer Group rejected' 'non-integer Group'

    $d = New-BaseDoc
    $d.Processors['rs-nonesuch'] = [ordered]@{ Group = '5'; Rank = '0'; Default = $false; Requires = @() }
    Assert-Throws { Import-Fixture $d } 'unknown fixed key rejected' 'has no processors'

    $d = New-BaseDoc
    $d.Routing.Remove('$strip')
    Assert-Throws { Import-Fixture $d } 'token without a Routing table rejected' 'no Routing table'

    $d = New-BaseDoc
    $d.Routing['$parse'] = [ordered]@{ powershell = [ordered]@{ extensions = @('ps1'); processor = 'rs-indent' } }
    Assert-Throws { Import-Fixture $d } 'Routing for an undeclared token rejected' 'no Processors entry'

    $d = New-BaseDoc
    $d.Routing['$strip'].csharp.processor = 'rs.cs.strip.ps1'
    Assert-Throws { Import-Fixture $d } 'route naming a filename rather than a key rejected' 'not a processor key'

    $d = New-BaseDoc
    $d.Routing['$strip'].csharp.processor = 'rs.cs.strip.cs'
    Assert-Throws { Import-Fixture $d } 'route naming a mistyped key rejected' 'not a processor key'

    $d = New-BaseDoc
    $d.Routing['$strip'].csharp.processor = 'rs.no.such'
    Assert-Throws { Import-Fixture $d } 'route naming an absent processor rejected' 'not a processor key'

    $d = New-BaseDoc
    $d.Routing['$strip'].csharp.extensions = @()
    Assert-Throws { Import-Fixture $d } 'route with no extensions rejected' 'no extensions'

    $d = New-BaseDoc
    $d.Routing['$strip'].csharp.extensions = @('ps1')
    Assert-Throws { Import-Fixture $d } 'extension claimed by two classes rejected' 'must be unambiguous'

    $d = New-BaseDoc
    $d.Processors['rs-content_meta'].Group = '3'
    Assert-Throws { Import-Fixture $d } 'Rank 0 beside other members rejected' 'reserves the group for one member'

    $d = New-BaseDoc
    $d.Processors['rs-whitespace'].Rank = '1'
    Assert-Throws { Import-Fixture $d } 'duplicate Rank within a group rejected' 'duplicate Ranks'

    $d = New-BaseDoc
    $d.Processors['rs-indent'].Requires = @('rs-content_meta')
    Assert-Throws { Import-Fixture $d } 'Requires edge pointing forward rejected' 'does not sort earlier'

    $d = New-BaseDoc
    $d.Processors['rs-indent'].Requires = @('rs-nonesuch')
    Assert-Throws { Import-Fixture $d } 'Requires naming an unknown entry rejected' 'no Processors entry'

    # -----------------------------------------------------------------------
    Enter-Section '3. Enablement is a set closed over Default and Requires'
    # -----------------------------------------------------------------------
    $enabled = Resolve-EnabledSet -Sequence $shipped -IncludeProcessors @('$strip', 'rs-indent', 'rs-whitespace', 'rs-content_meta')
    Assert-True ($enabled.Count -eq 5) 'closure pulled file-read in' "got $($enabled -join ', ')"
    Assert-True ($enabled -contains 'file-read') 'Default entry enabled without being named'

    $permuted = Resolve-EnabledSet -Sequence $shipped -IncludeProcessors @('rs-content_meta', 'rs-whitespace', '$strip', 'rs-indent')
    Assert-True (@(Compare-Object $enabled $permuted).Count -eq 0) 'array position in IncludeProcessors is ignored'

    $bare = Resolve-EnabledSet -Sequence $shipped -IncludeProcessors @()
    Assert-True ((@($bare) -join ',') -eq 'file-read') 'empty selection yields the Default set alone' (@($bare) -join ',')

    Assert-Throws { Resolve-EnabledSet -Sequence $shipped -IncludeProcessors @('rs-nonesuch') } `
        'naming an unregistered processor is a terminating error' 'RunVerbatim'

    # -----------------------------------------------------------------------
    Enter-Section '4. Classes are only those the corpus contains'
    # -----------------------------------------------------------------------
    $psOnly = Resolve-Classes -Sequence $shipped -Enabled $enabled -Extensions @('.ps1', '.psm1')
    Assert-True ((@($psOnly) -join ',') -eq 'powershell') `
        'all-PowerShell corpus compiles no default variant' "got $(@($psOnly) -join ', ')"

    $mixed = Resolve-Classes -Sequence $shipped -Enabled $enabled -Extensions @('.ps1', '.cs', '.md')
    Assert-True (@($mixed).Count -eq 3) 'three classes for ps/cs/md' "got $($mixed -join ', ')"
    Assert-True ($mixed -contains 'powershell' -and $mixed -contains 'csharp' -and $mixed -contains 'default') `
        'powershell, csharp and default all present'

    $dotless = Resolve-Classes -Sequence $shipped -Enabled $enabled -Extensions @('ps1')
    Assert-True ($dotless -contains 'powershell') 'dot-less extensions normalize on the way in'

    $noToken = Resolve-Classes -Sequence $shipped -Enabled @('file-read', 'rs-whitespace') -Extensions @('.ps1', '.cs')
    Assert-True ((@($noToken) -join ',') -eq 'default') `
        'a disabled token claims nothing' "got $(@($noToken) -join ', ')"

    # -----------------------------------------------------------------------
    Enter-Section '5. Variants are dense, ordered, and differ in length'
    # -----------------------------------------------------------------------
    $variants = Resolve-Variants -Sequence $shipped -Enabled $enabled -Classes $mixed

    $psKeys = @($variants['powershell'] | ForEach-Object Key)
    $csKeys = @($variants['csharp'] | ForEach-Object Key)
    $defKeys = @($variants['default'] | ForEach-Object Key)

    Assert-True (($psKeys -join ' > ') -eq 'file-read > rs.ps.strip > rs-indent > rs-whitespace > rs-content_meta') `
        'powershell chain in canon order' ($psKeys -join ' > ')
    Assert-True (($csKeys -join ' > ') -eq 'file-read > rs.cs.strip > rs-indent > rs-whitespace > rs-content_meta') `
        'csharp chain swaps only the stripper' ($csKeys -join ' > ')
    Assert-True (($defKeys -join ' > ') -eq 'file-read > rs-indent > rs-whitespace > rs-content_meta') `
        'unrouted class splices the token out' ($defKeys -join ' > ')
    Assert-True ($defKeys.Count -eq $psKeys.Count - 1) 'default chain is exactly one step shorter'
    Assert-True ($defKeys -notcontains $null -and $defKeys -notcontains '') 'no tombstone steps survive'

    Assert-True ($variants['powershell'][1].Slot -eq '$strip') 'routed step reports the token it filled'
    Assert-True ($variants['powershell'][2].Slot -eq 'rs-indent') 'fixed step reports itself as its slot'
    Assert-True ($variants['default'][0].Config -is [System.Collections.IDictionary]) 'steps carry a Config bag for the binder'

    # -----------------------------------------------------------------------
    Enter-Section '6. Ordering is declared, never inferred from layout'
    # -----------------------------------------------------------------------
    $shuffled = New-BaseDoc
    $reordered = [ordered]@{}
    foreach ($k in @('rs-content_meta', 'rs-whitespace', '$strip', 'rs-indent', 'file-read'))
    {
        $reordered[$k] = $shuffled.Processors[$k]
    }
    $shuffled.Processors = $reordered

    $shuffledSeq = Import-Fixture $shuffled
    $shuffledEnabled = Resolve-EnabledSet -Sequence $shuffledSeq -IncludeProcessors @('$strip', 'rs-indent', 'rs-whitespace', 'rs-content_meta')
    $shuffledVariants = Resolve-Variants -Sequence $shuffledSeq -Enabled $shuffledEnabled -Classes @('powershell')
    $shuffledKeys = @($shuffledVariants['powershell'] | ForEach-Object Key)

    Assert-True (($shuffledKeys -join ' > ') -eq ($psKeys -join ' > ')) `
        'permuting Processors keys changes no compiled chain' ($shuffledKeys -join ' > ')

    $regrouped = New-BaseDoc
    $regrouped.Processors['rs-indent'].Rank = '2'
    $regrouped.Processors['rs-whitespace'].Rank = '1'
    $regroupedSeq = Import-Fixture $regrouped
    $regroupedEnabled = Resolve-EnabledSet -Sequence $regroupedSeq -IncludeProcessors @('rs-indent', 'rs-whitespace')
    $regroupedVariants = Resolve-Variants -Sequence $regroupedSeq -Enabled $regroupedEnabled -Classes @('default')
    $regroupedKeys = @($regroupedVariants['default'] | ForEach-Object Key)

    Assert-True (($regroupedKeys -join ' > ') -eq 'file-read > rs-whitespace > rs-indent') `
        'swapping Rank swaps the compiled order' ($regroupedKeys -join ' > ')
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
Write-Host "`n═══ colonel-sequencing: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
