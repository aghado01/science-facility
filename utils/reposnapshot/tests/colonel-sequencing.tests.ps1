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
    Enter-Section '4. One walk of the canon compiles the chain an extension gets'
    # -----------------------------------------------------------------------
    $procs = $shipped.Processors
    $ordered = @(@($enabled) | Sort-Object { $procs[$_].Group }, { $procs[$_].Rank })

    $chainOf = { param($ext) @((Resolve-Chain -Sequence $shipped -OrderedSlots $ordered -Extension $ext) | ForEach-Object Key) -join ' > ' }

    Assert-True ((& $chainOf '.ps1') -eq 'file_read > rs.ps.strip > rs.indent > rs.whitespace > rs.content_meta') `
        'the powershell chain, in canon order' (& $chainOf '.ps1')
    Assert-True ((& $chainOf '.cs') -eq 'file_read > rs.cs.strip > rs.indent > rs.whitespace > rs.content_meta') `
        'the csharp chain swaps only the stripper' (& $chainOf '.cs')
    Assert-True ((& $chainOf '.md') -eq 'file_read > rs.indent > rs.whitespace > rs.content_meta') `
        'an unclaimed extension splices the routed slot out' (& $chainOf '.md')
    Assert-True ((& $chainOf 'ps1') -eq (& $chainOf '.ps1')) 'dot-less input normalizes on the way in'
    Assert-True ((& $chainOf '') -eq (& $chainOf '.md')) 'no extension resolves like an unclaimed one'

    $steps = @(Resolve-Chain -Sequence $shipped -OrderedSlots $ordered -Extension '.ps1')
    Assert-True ($steps[1].Slot -eq 'StripComments') 'a routed step reports the slot it filled'
    Assert-True ($steps[2].Slot -eq 'Indentation') 'a fixed step reports its own slot'
    Assert-True ($steps[0].Config -is [System.Collections.IDictionary]) 'steps carry a Config bag for the binder'
    Assert-True (@($steps | ForEach-Object Key) -notcontains $null) 'no tombstone steps survive'

    $noSlotOrdered = @(@('file_read', 'Whitespace') | Sort-Object { $procs[$_].Group }, { $procs[$_].Rank })
    $noSlotChain = @((Resolve-Chain -Sequence $shipped -OrderedSlots $noSlotOrdered -Extension '.ps1') | ForEach-Object Key) -join ' > '
    Assert-True ($noSlotChain -eq 'file_read > rs.whitespace') 'a disabled routed slot claims nothing' $noSlotChain

    # -----------------------------------------------------------------------
    Enter-Section '5. Interning is a cache over unique extensions'
    # -----------------------------------------------------------------------
    $psOnly = Resolve-Family -Sequence $shipped -Enabled $enabled -Extensions @('.ps1', '.psm1', '.psd1')
    Assert-True ($psOnly.ExtensionMap['.ps1'] -eq $psOnly.ExtensionMap['.psm1'] -and
        $psOnly.ExtensionMap['.psm1'] -eq $psOnly.ExtensionMap['.psd1']) `
        'sibling extensions share one chain — because their chains agree, not their names'
    Assert-True (@($psOnly.Variants.Keys).Count -eq 2) `
        'two chains: the shared PowerShell one, and pass-through' (@($psOnly.Variants.Keys) -join ',')
    Assert-True ($null -ne $psOnly.DefaultVariant -and $psOnly.DefaultVariant -ne $psOnly.ExtensionMap['.ps1']) `
        'pass-through is compiled even when every corpus extension is routed'
    $bareChain = @($psOnly.Variants[$psOnly.DefaultVariant] | ForEach-Object Key) -join ' > '
    Assert-True ($bareChain -eq 'file_read > rs.indent > rs.whitespace > rs.content_meta') `
        'and it is the canon minus the routed slot, not an empty chain' $bareChain

    $mixed = Resolve-Family -Sequence $shipped -Enabled $enabled -Extensions @('ps1', '.cs', '.md', '.py')
    Assert-True (@($mixed.Variants.Keys).Count -eq 3) 'ps/cs/md/py needs three chains' `
        (@($mixed.Variants.Keys) -join ',')
    Assert-True ($mixed.ExtensionMap['.md'] -eq $mixed.ExtensionMap['.py']) `
        'two unclaimed extensions share the unrouted chain'
    Assert-True ($mixed.DefaultVariant -eq $mixed.ExtensionMap['.md']) `
        'and DefaultVariant names it'

    # The id is opaque: it carries no meaning to read, only identity to compare.
    Assert-True (@($mixed.Variants.Keys | Sort-Object) -join ',' -eq '0,1,2') `
        'ids are ordinals, not labels' (@($mixed.Variants.Keys | Sort-Object) -join ',')
    $again = Resolve-Family -Sequence $shipped -Enabled $enabled -Extensions @('.py', '.md', '.cs', 'ps1')
    Assert-True ($again.ExtensionMap['.ps1'] -eq $mixed.ExtensionMap['.ps1']) `
        'and stable across runs regardless of the order extensions arrive in'

    $mixedPs = @($mixed.Variants[$mixed.ExtensionMap['.ps1']] | ForEach-Object Key) -join ' > '
    Assert-True ($mixedPs -eq 'file_read > rs.ps.strip > rs.indent > rs.whitespace > rs.content_meta') `
        'the interned chain is the compiled chain' $mixedPs

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
    $shuffledFamily = Resolve-Family -Sequence $shuffledSeq -Enabled $shuffledEnabled -Extensions @('.ps1')
    $shuffledKeys = @($shuffledFamily.Variants[$shuffledFamily.ExtensionMap['.ps1']] | ForEach-Object Key)

    Assert-True (($shuffledKeys -join ' > ') -eq (& $chainOf '.ps1')) `
        'permuting Processors keys changes no compiled chain' ($shuffledKeys -join ' > ')

    $regrouped = New-BaseDoc
    $regrouped.Processors['Indentation'].Rank = 2
    $regrouped.Processors['Whitespace'].Rank = 1
    $regroupedSeq = Import-Fixture $regrouped
    $regroupedEnabled = Resolve-EnabledSet -Sequence $regroupedSeq -IncludeProcessors @('Indentation', 'Whitespace')
    $regroupedFamily = Resolve-Family -Sequence $regroupedSeq -Enabled $regroupedEnabled -Extensions @('.md')
    $regroupedKeys = @($regroupedFamily.Variants[$regroupedFamily.ExtensionMap['.md']] | ForEach-Object Key)

    Assert-True (($regroupedKeys -join ' > ') -eq 'file_read > rs.whitespace > rs.indent') `
        'swapping Rank swaps the compiled order' ($regroupedKeys -join ' > ')

    # -----------------------------------------------------------------------
    Enter-Section '7. Compile-Plan emits the family'
    # -----------------------------------------------------------------------
    $chainExec = Join-Path $procDir 'chain_executor.ps1'
    $bagHelpers = Join-Path $procDir 'bag_helpers.ps1'
    $seqPath = Join-Path $procDir 'default_sequencer.json'

    $compiled = Compile-Plan -Manifest $manifest -SequenceManifest $seqPath `
        -IncludeProcessors $allSlots -Extensions @('.ps1', '.cs', '.md') `
        -ChainExecutorPath $chainExec -SharedHelperPath $bagHelpers

    Assert-True (@($compiled.Errors).Count -eq 0) 'a mixed corpus compiles clean' ($compiled.Errors -join '; ')
    Assert-True ($null -ne $compiled.Plan) 'a plan is produced'
    Assert-True (@($compiled.Plan.Variants.Keys).Count -eq 3) 'three variants compiled' `
        ((@($compiled.Plan.Variants.Keys) | Sort-Object) -join ', ')

    $psChain = @($compiled.Plan.Variants[$compiled.Plan.Routing['.ps1']] | ForEach-Object Key)
    $defChain = @($compiled.Plan.Variants[$compiled.Plan.Routing['.md']] | ForEach-Object Key)
    Assert-True (($psChain -join ' > ') -eq 'file_read > rs.ps.strip > rs.indent > rs.whitespace > rs.content_meta') `
        'the powershell chain binds in canon order' ($psChain -join ' > ')
    Assert-True ($defChain.Count -eq ($psChain.Count - 1)) 'the unrouted chain is one step shorter'

    Assert-True ($compiled.Plan.Routing['.ps1'] -ne $compiled.Plan.Routing['.md']) `
        'Routing sends the two classes to different chains'
    Assert-True ($compiled.Plan.DefaultVariant -eq $compiled.Plan.Routing['.md']) `
        'DefaultVariant names the unrouted chain'

    $issKeys = (@($compiled.Plan.ProcessorKeys) | Sort-Object) -join ','
    Assert-True ($issKeys -eq 'file_read,rs.content_meta,rs.cs.strip,rs.indent,rs.ps.strip,rs.whitespace') `
        'the ISS registers the union across variants — both strippers' $issKeys

    # The chain carries the resolution itself: every step names the slot it fills
    # alongside the implementation, so there is no parallel structure to consult.
    $psSteps = @($compiled.Plan.Variants[$compiled.Plan.Routing['.ps1']])
    $stripStep = @($psSteps | Where-Object Slot -eq 'StripComments')[0]
    Assert-True ($stripStep.Key -eq 'rs.ps.strip') 'a bound step names slot and implementation together'
    Assert-True ($stripStep.Config['Slot'] -eq 'StripComments') 'the slot rides in config, for the Processing trail'
    Assert-True ($stripStep.Fn -eq 'Invoke-rs.ps.strip') 'the bound Fn is the resolved processor, never the slot'

    $csSteps = @($compiled.Plan.Variants[$compiled.Plan.Routing['.cs']])
    $csStep = @($csSteps | Where-Object Slot -eq 'StripComments')[0]
    Assert-True ($csStep.Key -eq 'rs.cs.strip') 'the same slot resolves to a different processor per chain'
    Assert-True (@($defChain | Where-Object { $_ -eq 'rs.ps.strip' -or $_ -eq 'rs.cs.strip' }).Count -eq 0) `
        'and the unrouted chain carries neither'

    # An all-PowerShell corpus needs no default variant, so none is compiled.
    $psOnlyPlan = Compile-Plan -Manifest $manifest -SequenceManifest $seqPath `
        -IncludeProcessors $allSlots -Extensions @('.ps1', '.psm1') `
        -ChainExecutorPath $chainExec -SharedHelperPath $bagHelpers
    Assert-True ($null -ne $psOnlyPlan.Plan.DefaultVariant) `
        'an all-PowerShell corpus still compiles pass-through, for files no route claims'
    Assert-True ($null -eq $psOnlyPlan.Plan.PSObject.Properties['Steps']) `
        'the Plan carries no single-chain view at all — Variants is the only representation'

    # -----------------------------------------------------------------------
    Enter-Section '8. The literal-chain path is unchanged'
    # -----------------------------------------------------------------------
    $legacy = Compile-Plan -Manifest $manifest `
        -Steps @(@{ Key = 'file_read'; Config = @{} }, @{ Key = 'rs.whitespace'; Config = @{} }) `
        -ChainExecutorPath $chainExec -SharedHelperPath $bagHelpers

    Assert-True (@($legacy.Errors).Count -eq 0) 'a literal Steps chain still compiles' ($legacy.Errors -join '; ')
    Assert-True ((@($legacy.Plan.Variants[$legacy.Plan.DefaultVariant] | ForEach-Object Key) -join ' > ') -eq 'file_read > rs.whitespace') `
        'the literal chain compiles verbatim, in the order given'
    Assert-True (@($legacy.Plan.Variants.Keys).Count -eq 1) 'a literal chain is a family of one'
    Assert-True ((@($legacy.Plan.Routing.Keys) -join ',') -eq '') `
        'that routes nothing, so DefaultVariant is what every item takes'

    $neither = Compile-Plan -Manifest $manifest -ChainExecutorPath $chainExec
    Assert-True ((@($neither.Errors) -join ';') -match 'Neither SequenceManifest nor Steps') `
        'supplying neither is a reported error, not a throw' (@($neither.Errors) -join ';')

    $badSeq = Compile-Plan -Manifest $manifest -ChainExecutorPath $chainExec `
        -SequenceManifest (Join-Path $fixtureRoot 'absent.json')
    Assert-True ((@($badSeq.Errors) -join ';') -match 'not found') `
        'an unreadable sequencer surfaces as Errors, not a throw' (@($badSeq.Errors) -join ';')

    # -----------------------------------------------------------------------
    Enter-Section '9. A heterogeneous corpus dispatches per file, in real runspaces'
    # -----------------------------------------------------------------------
    # The payoff, and the only place per-item routing is observable: four languages,
    # two of them routed. Read back from the Processing trail each item carries home.
    $langRoot = Join-Path $PSScriptRoot 'languages'
    $specimens = @(
        @{ Rel = 'powershell\collapse.ps1'; Ext = '.ps1' }
        @{ Rel = 'csharp\GaussianManifold.cs'; Ext = '.cs' }
        @{ Rel = 'python\bench.py'; Ext = '.py' }
        @{ Rel = 'typescript\linter-ts.ts'; Ext = '.ts' }
    )
    $items = @(
        foreach ($s in $specimens)
        {
            [pscustomobject]@{
                AbsolutePath = (Join-Path $langRoot $s.Rel)
                RelativePath = $s.Rel
                Extension    = $s.Ext
            }
        }
    )
    Assert-True (@($items | Where-Object { Test-Path -LiteralPath $_.AbsolutePath }).Count -eq 4) `
        'four language specimens are on disk'

    $hetPlan = Compile-Plan -Manifest $manifest -SequenceManifest $seqPath `
        -IncludeProcessors $allSlots -Extensions @($items | ForEach-Object Extension) `
        -ChainExecutorPath $chainExec -SharedHelperPath $bagHelpers
    Assert-True (@($hetPlan.Errors).Count -eq 0) 'the heterogeneous corpus compiles' ($hetPlan.Errors -join '; ')

    $run = Invoke-Plan -Items $items -Plan $hetPlan.Plan -MaxWorkers 2
    Assert-True (@($run.Errors).Count -eq 0) 'dispatch reports no errors' (@($run.Errors) -join '; ')
    Assert-True (@($run.Results).Count -eq 4) 'every item came back'

    $backRel = @($run.Results | ForEach-Object RelativePath)
    Assert-True (($backRel -join ',') -eq ((@($items | ForEach-Object RelativePath)) -join ',')) `
        'results stay index-stable across variants of differing length' ($backRel -join ',')

    $trail = { param($r) @($r.Processing | ForEach-Object { "$($_.Processor):$($_.Implementation)" }) }
    $psTrail = & $trail $run.Results[0]
    $csTrail = & $trail $run.Results[1]
    $pyTrail = & $trail $run.Results[2]
    $tsTrail = & $trail $run.Results[3]

    Assert-True ($psTrail -contains 'StripComments:rs.ps.strip') `
        'the .ps1 ran the PowerShell stripper' ($psTrail -join ' > ')
    Assert-True ($csTrail -contains 'StripComments:rs.cs.strip') `
        'the .cs ran the C# stripper under the SAME slot — one capability, two implementations' ($csTrail -join ' > ')
    Assert-True (@($run.Results[2].Processing | Where-Object Processor -eq 'StripComments').Count -eq 0) `
        'the .py resolved no stripper, so the slot spliced out' ($pyTrail -join ' > ')
    Assert-True (@($run.Results[3].Processing | Where-Object Processor -eq 'StripComments').Count -eq 0) `
        'the .ts likewise' ($tsTrail -join ' > ')
    Assert-True ($pyTrail.Count -eq ($psTrail.Count - 1)) `
        'the unrouted chain is exactly one record shorter'

    foreach ($r in $run.Results)
    {
        $slots = @($r.Processing | ForEach-Object Processor)
        Assert-True (($slots -contains 'Indentation') -and ($slots -contains 'Whitespace')) `
            "$($r.RelativePath): the fixed slots ran" ($slots -join ' > ')
    }
    Assert-True (@($run.Results | Where-Object { $null -ne $_.PSObject.Properties['ContentMeta'] }).Count -eq 4) `
        'measurement ran on every variant'

    # The trail names the capability; provenance is not lost to it.
    Assert-True (@($run.Results[0].Processing | Where-Object Processor -eq 'Indentation').Implementation -eq 'rs.indent') `
        'a fixed slot reports its capability, with the implementation alongside'

    # -----------------------------------------------------------------------
    Enter-Section '10. A file no route claims passes through, it does not fail'
    # -----------------------------------------------------------------------
    # Requesting StripComments over a corpus means "strip where a stripper exists".
    # A file with an extension no stripper covers — or with none at all, which is
    # what a Makefile or a LICENSE looks like — still flows through the rest of the
    # canon, one step shorter. Compiling only the routed chains would strand it.
    $throughPlan = Compile-Plan -Manifest $manifest -SequenceManifest $seqPath `
        -IncludeProcessors $allSlots -Extensions @('.ps1') `
        -ChainExecutorPath $chainExec -SharedHelperPath $bagHelpers

    $throughItems = @(
        [pscustomobject]@{ AbsolutePath = (Join-Path $langRoot 'powershell\collapse.ps1'); RelativePath = 'collapse.ps1'; Extension = '.ps1' }
        [pscustomobject]@{ AbsolutePath = (Join-Path $langRoot 'python\bench.py'); RelativePath = 'LICENSE'; Extension = '' }
    )
    $throughRun = Invoke-Plan -Items $throughItems -Plan $throughPlan.Plan -MaxWorkers 2

    Assert-True (@($throughRun.Errors).Count -eq 0) `
        'an extensionless file in a routed corpus is not an error' (@($throughRun.Errors) -join ' | ')
    Assert-True ($null -ne $throughRun.Results[1]) 'it comes back processed, not null'

    $throughSlots = @($throughRun.Results[1].Processing | ForEach-Object Processor)
    Assert-True (($throughSlots -contains 'Indentation') -and ($throughSlots -contains 'Whitespace')) `
        'having run every stage the canon still had for it' ($throughSlots -join ' > ')
    Assert-True ($throughSlots -notcontains 'StripComments') `
        'minus the one no route claimed'
    Assert-True ($null -ne $throughRun.Results[1].PSObject.Properties['ContentMeta']) `
        'and measured, like any other entry'
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
