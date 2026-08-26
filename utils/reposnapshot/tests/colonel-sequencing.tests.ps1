#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Sequencer resolution tests for rs.core.colonel.v2 (enable → route → sort).

.DESCRIPTION
    Covers the four resolvers that turn processors/default_sequencer.json into a
    plan family:
      1. Import-SequenceManifest loads the shipped sequencer and normalizes it
      2. Declared conventions are enforced, each as a terminating error
      3. Resolve-EnabledSet treats IncludeProcessors as a set and closes Requires
      4. Resolve-Routing maps extensions onto variants by resolution tuple
      5. Resolve-Variants emits dense per-variant chains ordered by (Group, Rank)
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
    if ($f.Name -in 'chain_executor.ps1', 'bag_helpers.ps1') { continue }
    $manifest[[IO.Path]::GetFileNameWithoutExtension($f.Name)] = $f.FullName
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-seq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null

function New-BaseDoc
{
    return [ordered]@{
        Processors = [ordered]@{
            'file_read'       = [ordered]@{ Group = 1; Rank = 0; Default = $true; File = 'file_read.ps1' }
            'StripComments'   = [ordered]@{
                Group = 2; Rank = 0; Default = $false; Requires = @('file_read')
                Routing = @(
                    [ordered]@{ File = 'rs.ps.strip.ps1'; Extensions = @('ps1', 'psm1', 'psd1') }
                    [ordered]@{ File = 'rs.cs.strip.ps1'; Extensions = @('cs', 'csx') }
                )
            }
            'Indentation'     = [ordered]@{ Group = 3; Rank = 1; Default = $false; File = 'rs.indent.ps1'; Requires = @('file_read') }
            'Whitespace'      = [ordered]@{ Group = 3; Rank = 2; Default = $false; File = 'rs.whitespace.ps1'; Requires = @('file_read') }
            'ContentMetadata' = [ordered]@{ Group = 4; Rank = 0; Default = $false; File = 'rs.content_meta.ps1'; Requires = @('file_read') }
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

$allSlots = @('StripComments', 'Indentation', 'Whitespace', 'ContentMetadata')

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. The shipped sequencer loads and normalizes'
    # -----------------------------------------------------------------------
    $shipped = Import-SequenceManifest -Path (Join-Path $procDir 'default_sequencer.json') -Manifest $manifest

    Assert-True ($shipped.Processors.Count -eq 5) 'five slots' "got $($shipped.Processors.Count)"
    Assert-True ($shipped.Processors['StripComments'].IsRouted) 'a Routing array marks the slot routed'
    Assert-True (-not $shipped.Processors['Indentation'].IsRouted) 'a File marks the slot fixed'
    Assert-True ($shipped.Processors['Indentation'].Key -eq 'rs.indent') 'fixed slot binds to its processor key'
    Assert-True ($null -eq $shipped.Processors['StripComments'].Key) 'routed slot binds to no single key'
    Assert-True ($shipped.Processors['file_read'].Default) 'file_read is Default'
    Assert-True (@($shipped.Processors['file_read'].Requires).Count -eq 0) 'an absent Requires normalizes to empty, not null'
    Assert-True ($shipped.Processors['Whitespace'].Rank -eq 2) 'Rank parsed as 2'
    Assert-True (@($shipped.Processors['StripComments'].Routes).Count -eq 2) 'two routes under StripComments'
    Assert-True ($shipped.Processors['StripComments'].Routes[0].Extensions -contains '.ps1') 'extensions normalize to leading dot'
    Assert-True ($shipped.Processors['StripComments'].Routes[0].Key -eq 'rs.ps.strip') 'route binds to its processor key'

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
    $d.Processors['Indentation'].Group = 'three'
    Assert-Throws { Import-Fixture $d } 'non-integer Group rejected' 'non-integer Group'

    $d = New-BaseDoc
    $d.Processors['Indentation'].Remove('File')
    Assert-Throws { Import-Fixture $d } 'slot with neither File nor Routing rejected' 'exactly one of File or Routing'

    $d = New-BaseDoc
    $d.Processors['StripComments'].File = 'rs.indent.ps1'
    Assert-Throws { Import-Fixture $d } 'slot with both File and Routing rejected' 'exactly one of File or Routing'

    $d = New-BaseDoc
    $d.Processors['Indentation'].File = 'rs.indent.cs'
    Assert-Throws { Import-Fixture $d } 'right stem, wrong extension rejected' 'but the processor on disk is'

    $d = New-BaseDoc
    $d.Processors['Indentation'].File = 'rs.no.such.ps1'
    Assert-Throws { Import-Fixture $d } 'File naming an absent processor rejected' 'no processor on disk'

    $d = New-BaseDoc
    $d.Processors['StripComments'].Routing[1].File = 'rs.cs.strip.cs'
    Assert-Throws { Import-Fixture $d } 'a mistyped route File rejected' 'but the processor on disk is'

    $d = New-BaseDoc
    $d.Processors['StripComments'].Routing[1].Extensions = @()
    Assert-Throws { Import-Fixture $d } 'route with no Extensions rejected' 'no Extensions'

    $d = New-BaseDoc
    $d.Processors['StripComments'].Routing[1].Extensions = @('ps1')
    Assert-Throws { Import-Fixture $d } 'one extension claimed by two routes of a slot rejected' 'claimed by two routes'

    $d = New-BaseDoc
    $d.Processors['ContentMetadata'].Group = 3
    Assert-Throws { Import-Fixture $d } 'Rank 0 beside other members rejected' 'reserves the group for one member'

    $d = New-BaseDoc
    $d.Processors['Whitespace'].Rank = 1
    Assert-Throws { Import-Fixture $d } 'duplicate Rank within a group rejected' 'duplicate Ranks'

    $d = New-BaseDoc
    $d.Processors['Indentation'].Requires = @('ContentMetadata')
    Assert-Throws { Import-Fixture $d } 'Requires edge pointing forward rejected' 'does not sort earlier'

    $d = New-BaseDoc
    $d.Processors['Indentation'].Requires = @('Nonesuch')
    Assert-Throws { Import-Fixture $d } 'Requires naming an unknown slot rejected' 'no Processors entry'

    # -----------------------------------------------------------------------
    Enter-Section '3. Enablement is a set closed over Default and Requires'
    # -----------------------------------------------------------------------
    $enabled = Resolve-EnabledSet -Sequence $shipped -IncludeProcessors $allSlots
    Assert-True (@($enabled).Count -eq 5) 'closure pulled file_read in' "got $(@($enabled) -join ', ')"
    Assert-True ($enabled -contains 'file_read') 'Default slot enabled without being named'

    $permuted = Resolve-EnabledSet -Sequence $shipped -IncludeProcessors @('ContentMetadata', 'Whitespace', 'StripComments', 'Indentation')
    Assert-True (@(Compare-Object $enabled $permuted).Count -eq 0) 'array position in IncludeProcessors is ignored'

    $bare = Resolve-EnabledSet -Sequence $shipped -IncludeProcessors @()
    Assert-True ((@($bare) -join ',') -eq 'file_read') 'empty selection yields the Default set alone' (@($bare) -join ',')

    Assert-Throws { Resolve-EnabledSet -Sequence $shipped -IncludeProcessors @('Nonesuch') } `
        'naming an unregistered slot is a terminating error' 'RunVerbatim'

    # -----------------------------------------------------------------------
    Enter-Section '4. Routing maps extensions onto variants by resolution tuple'
    # -----------------------------------------------------------------------
    $psOnly = Resolve-Routing -Sequence $shipped -Enabled $enabled -Extensions @('.ps1', '.psm1')
    Assert-True (@($psOnly.Resolutions.Keys) -notcontains 'default') 'an all-PowerShell corpus compiles no default variant' `
        "got $(@($psOnly.Resolutions.Keys) -join ', ')"
    Assert-True ($psOnly.ExtensionMap['.ps1'] -eq $psOnly.ExtensionMap['.psm1']) 'sibling extensions share one variant'
    Assert-True (@($psOnly.Resolutions.Keys).Count -eq 1) 'and that variant is compiled once'

    $mixed = Resolve-Routing -Sequence $shipped -Enabled $enabled -Extensions @('ps1', '.cs', '.md', '.py')
    Assert-True (@($mixed.Resolutions.Keys).Count -eq 3) 'ps/cs/md/py yields three variants' `
        "got $(@($mixed.Resolutions.Keys) -join ', ')"
    Assert-True ($mixed.ExtensionMap['.ps1'] -eq 'rs.ps.strip') 'variant key is the resolution itself'
    Assert-True ($mixed.ExtensionMap['.md'] -eq 'default' -and $mixed.ExtensionMap['.py'] -eq 'default') `
        'unclaimed extensions collapse onto one default variant'
    Assert-True ($mixed.ExtensionMap.ContainsKey('.ps1')) 'dot-less input normalized on the way in'

    $noSlot = Resolve-Routing -Sequence $shipped -Enabled @('file_read', 'Whitespace') -Extensions @('.ps1', '.cs')
    Assert-True ((@($noSlot.Resolutions.Keys) -join ',') -eq 'default') 'a disabled routed slot claims nothing' `
        (@($noSlot.Resolutions.Keys) -join ',')

    # -----------------------------------------------------------------------
    Enter-Section '5. Variants are dense, ordered, and differ in length'
    # -----------------------------------------------------------------------
    $variants = Resolve-Variants -Sequence $shipped -Enabled $enabled -Resolutions $mixed.Resolutions

    $psKeys = @($variants['rs.ps.strip'] | ForEach-Object Key)
    $csKeys = @($variants['rs.cs.strip'] | ForEach-Object Key)
    $defKeys = @($variants['default'] | ForEach-Object Key)

    Assert-True (($psKeys -join ' > ') -eq 'file_read > rs.ps.strip > rs.indent > rs.whitespace > rs.content_meta') `
        'powershell chain in canon order' ($psKeys -join ' > ')
    Assert-True (($csKeys -join ' > ') -eq 'file_read > rs.cs.strip > rs.indent > rs.whitespace > rs.content_meta') `
        'csharp chain swaps only the stripper' ($csKeys -join ' > ')
    Assert-True (($defKeys -join ' > ') -eq 'file_read > rs.indent > rs.whitespace > rs.content_meta') `
        'unrouted class splices the slot out' ($defKeys -join ' > ')
    Assert-True ($defKeys.Count -eq $psKeys.Count - 1) 'default chain is exactly one step shorter'
    Assert-True ($defKeys -notcontains $null -and $defKeys -notcontains '') 'no tombstone steps survive'

    Assert-True ($variants['rs.ps.strip'][1].Slot -eq 'StripComments') 'routed step reports the slot it filled'
    Assert-True ($variants['rs.ps.strip'][2].Slot -eq 'Indentation') 'fixed step reports its own slot'
    Assert-True ($variants['default'][0].Config -is [System.Collections.IDictionary]) 'steps carry a Config bag for the binder'

    # -----------------------------------------------------------------------
    Enter-Section '6. Ordering is declared, never inferred from layout'
    # -----------------------------------------------------------------------
    $shuffled = New-BaseDoc
    $reordered = [ordered]@{}
    foreach ($k in @('ContentMetadata', 'Whitespace', 'StripComments', 'Indentation', 'file_read'))
    {
        $reordered[$k] = $shuffled.Processors[$k]
    }
    $shuffled.Processors = $reordered

    $shuffledSeq = Import-Fixture $shuffled
    $shuffledEnabled = Resolve-EnabledSet -Sequence $shuffledSeq -IncludeProcessors $allSlots
    $shuffledRouting = Resolve-Routing -Sequence $shuffledSeq -Enabled $shuffledEnabled -Extensions @('.ps1')
    $shuffledVariants = Resolve-Variants -Sequence $shuffledSeq -Enabled $shuffledEnabled -Resolutions $shuffledRouting.Resolutions
    $shuffledKeys = @($shuffledVariants['rs.ps.strip'] | ForEach-Object Key)

    Assert-True (($shuffledKeys -join ' > ') -eq ($psKeys -join ' > ')) `
        'permuting Processors keys changes no compiled chain' ($shuffledKeys -join ' > ')

    $regrouped = New-BaseDoc
    $regrouped.Processors['Indentation'].Rank = 2
    $regrouped.Processors['Whitespace'].Rank = 1
    $regroupedSeq = Import-Fixture $regrouped
    $regroupedEnabled = Resolve-EnabledSet -Sequence $regroupedSeq -IncludeProcessors @('Indentation', 'Whitespace')
    $regroupedRouting = Resolve-Routing -Sequence $regroupedSeq -Enabled $regroupedEnabled -Extensions @('.md')
    $regroupedVariants = Resolve-Variants -Sequence $regroupedSeq -Enabled $regroupedEnabled -Resolutions $regroupedRouting.Resolutions
    $regroupedKeys = @($regroupedVariants['default'] | ForEach-Object Key)

    Assert-True (($regroupedKeys -join ' > ') -eq 'file_read > rs.whitespace > rs.indent') `
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
