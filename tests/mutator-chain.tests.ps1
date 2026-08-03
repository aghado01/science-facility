#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Content mutators inside a code-track chain: crawl → ignore →
    ingest[file-read, format-ws, rs-psstrip, rs-attributes] → assemble.

.DESCRIPTION
    The regression for consolidation item 6d. Before harmonization, format-ws
    and rs-psstrip spoke the tp-era contract — they unpacked $Item.Text and
    REPLACED the bag with an Id/Path/Text envelope, so putting either one in a
    code-track chain destroyed the ItemDescriptor identity fields and assemble
    could not key an entry. That is why the golden validation ran a chain of
    only [file-read, rs-attributes] over normal-form content: content-transform
    parity was blocked, not merely untested.

    This suite asserts the capability 6d unblocked, end to end and through
    colonel's real runspace dispatch (which also re-proves the harmonized
    processors are still ISS-load-safe):

      1. Identity survives two content mutators — RelativePath, NodePath,
         LastWriteUtc intact; Content never renamed; no tp-era Id/Text/Path
         envelope residue anywhere in the IR.
      2. Both mutations actually applied (the chain is doing work, not
         passing through): CRLF normalized + trailing whitespace gone by
         format-ws; comment kinds stripped and FrontMatter preserved by
         rs-psstrip.
      3. The `Processing` trail is collated as an ORDINARY element — order is
         chain order, and Header.Elements declares it without assemble
         knowing the element exists (open element model, zero per-element
         branches).
      4. Byte layers stay distinct after mutation: Attributes.SpanBytes is the
         UTF-8 span of the POST-mutation content and is smaller than the
         on-disk size; SizeBytes is absent from the entry (descriptor
         bookkeeping, excluded by assemble). See the payload doctrine —
         SizeBytes vs SpanBytes vs rendered row length are three layers.

    The harness plays admiral (build-against-absent-admiral rule), same as
    pipeline.smoke.tests.ps1.

.NOTES
    Run from any directory:
        & "$PSScriptRoot\mutator-chain.tests.ps1"
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'

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

# ---------------------------------------------------------------------------
# Fixture — CRLF line endings, trailing whitespace, every comment kind, and a
# #Requires directive so FrontMatter preservation is exercised under mutation.
# ---------------------------------------------------------------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-mutator-chain-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'src') -Force | Out-Null

$psSource = @"
#Requires -Version 7.0
# a standalone comment
# a second line making a block

function Get-Thing
{
    <# docstring #>
    `$x = 1   # inline kept
    return `$x
}
"@
# CRLF + trailing whitespace + trailing blank lines, so format-ws has real work
$psSource = ($psSource -replace "`n", "`r`n") + "   `r`n`r`n`r`n`r`n"
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'src\thing.ps1'), $psSource, [System.Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $fixtureRoot 'src\plain.txt'), "just text`r`nsecond   line", [System.Text.UTF8Encoding]::new($false))

$onDiskBytes = [System.Text.Encoding]::UTF8.GetByteCount($psSource)

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. Pipeline runs with two content mutators in the chain'
    # -----------------------------------------------------------------------
    Import-Module (Join-Path $v3 'rs.core.crawler.psm1') -Force
    Import-Module (Join-Path $v3 'rs.core.ignore.psm1') -Force
    Import-Module (Join-Path $v3 'rs.core.colonel.v2.psm1') -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $v3 'rs.core.ingest.psm1') -Force
    Import-Module (Join-Path $v3 'rs.core.assemble.psm1') -Force

    $crawl = (New-FileSystemCrawler -RootPath $fixtureRoot).Invoke()
    $compiled = New-IgnoreCompiler -CrawlerGraph $crawl.Graph
    $filtered = Invoke-IgnoreFilter -CompiledNodes $compiled.CompiledNodes -CrawlerGraph $crawl.Graph

    # The profile 6d unblocked: reader → whitespace mutator → language-specific
    # mutator → enrich-only tail. Position doctrine: rs-attributes LAST, after
    # ALL content mutators (its metrics describe what the reader will receive).
    $ingest = Invoke-Ingest -FilteredFsGraph $filtered `
        -Manifest @{
            'file-read'     = (Join-Path $v3 'processors\file-read.ps1')
            'format'        = (Join-Path $v3 'processors\format-ws.ps1')
            'rs-psstrip'    = (Join-Path $v3 'processors\rs-psstrip.ps1')
            'rs-attributes' = (Join-Path $v3 'processors\rs-attributes.ps1')
        } `
        -Steps @(
            @{ Key = 'file-read'; Config = @{} }
            @{ Key = 'format'; Config = @{ Operations = @('lf', 'trim-trailing', 'trim-doc') } }
            @{ Key = 'rs-psstrip'; Config = @{ Operations = @('block-comments', 'doc-strings', 'comment-blocks', 'line-comments') } }
            @{ Key = 'rs-attributes'; Config = @{} }
        ) `
        -ChainExecutorPath (Join-Path $v3 'processors\chain-executor.ps1')

    Assert-True ($null -ne $ingest) 'ingest returned a dispatch envelope'
    Assert-True (@($ingest.Errors).Count -eq 0) 'no per-item dispatch errors' "errors: $(@($ingest.Errors) -join '; ')"

    $ir = Invoke-Assemble -DispatchOutput $ingest -RunContext ([pscustomobject]@{
            Root = $fixtureRoot; GeneratorVersion = '3.0' })
    Assert-True ($null -ne $ir) 'assemble produced an IR'
    Assert-True (@($ir.Entries).Count -eq 2) 'both files assembled' "got $(@($ir.Entries).Count)"
    Assert-True (@($ir.Diagnostics.Routed).Count -eq 0) 'nothing misrouted to Diagnostics'

    $entry = $ir.Entries | Where-Object { $_.RelativePath -eq 'src/thing.ps1' }
    Assert-True ($null -ne $entry) 'src/thing.ps1 present in IR entries'

    # -----------------------------------------------------------------------
    Enter-Section '2. Identity survives the mutator chain (the 6d fault line)'
    # -----------------------------------------------------------------------
    Assert-True ($entry.RelativePath -eq 'src/thing.ps1') 'RelativePath intact after format-ws + rs-psstrip'
    Assert-True ($entry.NodePath -eq 'src/') 'NodePath intact'
    Assert-True ($entry.LastWriteUtc -is [datetime]) 'LastWriteUtc intact and still typed'
    Assert-True ($null -ne $entry.PSObject.Properties['Content']) 'Content key present (never renamed to Text)'
    Assert-True ($null -eq $entry.PSObject.Properties['Text']) 'no Text key leaked into the IR'
    Assert-True ($null -eq $entry.PSObject.Properties['Id']) 'no tp-era Id envelope field leaked'
    Assert-True ($null -eq $entry.PSObject.Properties['Path']) 'no tp-era Path envelope field leaked'

    # -----------------------------------------------------------------------
    Enter-Section '3. Both mutations actually applied'
    # -----------------------------------------------------------------------
    Assert-True ($entry.Content -notmatch "`r") 'format-ws: CRLF normalized to LF'
    Assert-True ($entry.Content -notmatch '(?m)[ \t]+$') 'format-ws: per-line trailing whitespace gone'
    Assert-True ($entry.Content -notmatch '\n\s*$') 'format-ws: trailing blank lines trimmed (trim-doc)'
    Assert-True ($entry.Content -notmatch 'a standalone comment') 'rs-psstrip: CommentBlock stripped'
    Assert-True ($entry.Content -notmatch 'docstring') 'rs-psstrip: DocString stripped'
    Assert-True ($entry.Content -match '(?m)^#Requires -Version 7\.0') 'rs-psstrip: FrontMatter preserved under mutation'
    Assert-True ($entry.Content -match 'inline kept') 'rs-psstrip: InlineComment kept (not in the op set)'
    Assert-True ($entry.Content -match 'function Get-Thing') 'code preserved through both mutators'

    # -----------------------------------------------------------------------
    Enter-Section '4. Processing trail collated as an ordinary element'
    # -----------------------------------------------------------------------
    Assert-True ($null -ne $entry.PSObject.Properties['Processing']) 'Processing element present on the entry'
    Assert-True (@($entry.Processing).Count -eq 2) 'one record per mutator invocation' "got $(@($entry.Processing).Count)"
    Assert-True ($entry.Processing[0].Processor -eq 'format') 'trail order[0] = format (chain order)'
    Assert-True ($entry.Processing[1].Processor -eq 'rs-psstrip') 'trail order[1] = rs-psstrip'
    Assert-True (@($entry.Processing[0].Operations).Count -eq 3) 'first record carries its own resolved ops'
    Assert-True (@($entry.Processing[1].Operations).Count -eq 4) 'second record carries its own resolved ops'
    Assert-True ($null -eq $entry.Processing[1].PSObject.Properties['ParseErrors']) 'clean parse: no ParseErrors on the record'

    # Open element model: assemble declares the element without knowing it exists.
    Assert-True ($null -ne $ir.Header.Elements.PSObject.Properties['Processing']) 'Header.Elements DECLARES Processing'
    Assert-True ($ir.Header.Elements.Processing.Count -eq 2) 'Header.Elements presence count = 2 entries' "got $($ir.Header.Elements.Processing.Count)"

    # -----------------------------------------------------------------------
    Enter-Section '5. Byte layers stay distinct after mutation'
    # -----------------------------------------------------------------------
    Assert-True ($null -ne $entry.PSObject.Properties['Attributes']) 'Attributes element present (enrich-only tail ran last)'
    $spanBytes = [System.Text.Encoding]::UTF8.GetByteCount($entry.Content)
    Assert-True ($entry.Attributes.SpanBytes -eq $spanBytes) 'SpanBytes = UTF-8 span of the POST-mutation content'
    Assert-True ($entry.Attributes.SpanBytes -lt $onDiskBytes) 'SpanBytes < on-disk size (mutation shrank the payload)' "span=$($entry.Attributes.SpanBytes) disk=$onDiskBytes"
    Assert-True ($null -eq $entry.PSObject.Properties['SizeBytes']) 'SizeBytes absent from the entry (descriptor bookkeeping)'

    # -----------------------------------------------------------------------
    Enter-Section '6. Serial and parallel dispatch agree'
    # -----------------------------------------------------------------------
    # Content mutators must be dispatch-mode invariant: the harmonized clone
    # happens per item with no shared state.
    $serial = Invoke-Ingest -FilteredFsGraph $filtered `
        -Manifest @{
            'file-read'  = (Join-Path $v3 'processors\file-read.ps1')
            'format'     = (Join-Path $v3 'processors\format-ws.ps1')
            'rs-psstrip' = (Join-Path $v3 'processors\rs-psstrip.ps1')
        } `
        -Steps @(
            @{ Key = 'file-read'; Config = @{} }
            @{ Key = 'format'; Config = @{ Operations = @('lf', 'trim-trailing', 'trim-doc') } }
            @{ Key = 'rs-psstrip'; Config = @{ Operations = @('block-comments', 'doc-strings', 'comment-blocks', 'line-comments') } }
        ) `
        -ChainExecutorPath (Join-Path $v3 'processors\chain-executor.ps1') `
        -MaxWorkers 1

    Assert-True ($serial.Budget.Threads -eq 1) 'serial run used one worker'
    $serialIr = Invoke-Assemble -DispatchOutput $serial
    $serialEntry = $serialIr.Entries | Where-Object { $_.RelativePath -eq 'src/thing.ps1' }
    Assert-True ($null -ne $serialEntry) 'serial dispatch: entry present'
    Assert-True ($serialEntry.Content -eq $entry.Content) 'serial content byte-identical to the parallel run'
    Assert-True (@($serialEntry.Processing).Count -eq 2) 'serial dispatch: same Processing trail length'
}
finally
{
    Remove-Item $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "═══ mutator-chain.tests: $($script:Passed) passed, $($script:Failed) failed ═══" -ForegroundColor $color
