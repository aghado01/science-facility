#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Processor-validation tests for rs.core.colonel.v2 Compile-Plan (AST contract).

.DESCRIPTION
    Covers the body-only processor contract after the AST fix:
      1. Interior helper functions are ACCEPTED — tp-perplexity (real file,
         contains `function _MaskByRegex`) compiles into a plan
      2. Outer-function-wrapper scripts are REJECTED (no top-level param block)
      3. Scripts without any param block are REJECTED
      4. #Requires directives are still REJECTED
      5. Non-parsing scripts are REJECTED with a parse message
      6. Interior helpers EXECUTE correctly inside a dispatched chain

.NOTES
    Run from any directory:
        & "$PSScriptRoot\colonel-validation.tests.ps1"
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'
$chainExec = Join-Path $v3 'processors\chain-executor.ps1'

# ---------------------------------------------------------------------------
# Minimal assertion framework (house pattern — see colonel.tests.ps1)
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

function Invoke-CompileOnly ([hashtable]$Manifest, [string]$Key)
{
    return Compile-Plan -Manifest $Manifest `
        -Steps @(@{ Key = $Key; Config = @{} }) `
        -ChainExecutorPath $chainExec
}

# ---------------------------------------------------------------------------
# Fixture processor scripts
# ---------------------------------------------------------------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rs-colonel-val-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null

Set-Content -Path (Join-Path $fixtureRoot 'wrapper.ps1') -Value @'
function Invoke-Wrapper
{
    param($Item, $Config)
    return $Item
}
'@

Set-Content -Path (Join-Path $fixtureRoot 'no-param.ps1') -Value @'
$x = 1
$x
'@

Set-Content -Path (Join-Path $fixtureRoot 'requires.ps1') -Value @'
#Requires -Version 7.0
param($Item, $Config)
return $Item
'@

Set-Content -Path (Join-Path $fixtureRoot 'broken.ps1') -Value @'
param($Item, $Config
return $Item
'@

Set-Content -Path (Join-Path $fixtureRoot 'helper.ps1') -Value @'
param($Item, $Config)

function _Twice
{
    param([int]$n)
    return $n * 2
}

$result = [PSCustomObject]@{}
foreach ($p in $Item.PSObject.Properties)
{
    $result | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
}
$result | Add-Member -NotePropertyName Doubled -NotePropertyValue (_Twice -n $Item.Value)
return $result
'@

try
{
    Import-Module (Join-Path $v3 'rs.core.colonel.v2.psm1') -Force -WarningAction SilentlyContinue

    # -----------------------------------------------------------------------
    Enter-Section '1. Interior helpers accepted — tp-perplexity compiles'
    # -----------------------------------------------------------------------
    $tp = Invoke-CompileOnly @{ 'tp-perplexity' = (Join-Path $v3 'processors\tp-perplexity.ps1') } 'tp-perplexity'
    Assert-True (@($tp.Errors).Count -eq 0) 'tp-perplexity (has _MaskByRegex) compiles clean' ($tp.Errors -join '; ')
    Assert-True ($null -ne $tp.Plan) 'plan produced'

    # -----------------------------------------------------------------------
    Enter-Section '2. Outer wrapper rejected'
    # -----------------------------------------------------------------------
    $w = Invoke-CompileOnly @{ 'wrapper' = (Join-Path $fixtureRoot 'wrapper.ps1') } 'wrapper'
    Assert-True (@($w.Errors).Count -gt 0) 'wrapper script rejected'
    Assert-True (($w.Errors -join ' ') -match 'top-level param') 'error names the param-block contract'

    # -----------------------------------------------------------------------
    Enter-Section '3. Missing param block rejected'
    # -----------------------------------------------------------------------
    $np = Invoke-CompileOnly @{ 'no-param' = (Join-Path $fixtureRoot 'no-param.ps1') } 'no-param'
    Assert-True (@($np.Errors).Count -gt 0) 'param-less script rejected'

    # -----------------------------------------------------------------------
    Enter-Section '4. #Requires still rejected'
    # -----------------------------------------------------------------------
    $rq = Invoke-CompileOnly @{ 'requires' = (Join-Path $fixtureRoot 'requires.ps1') } 'requires'
    Assert-True ((@($rq.Errors) -join ' ') -match 'Requires') '#Requires rejected with ISS-load message'

    # -----------------------------------------------------------------------
    Enter-Section '5. Parse errors rejected'
    # -----------------------------------------------------------------------
    $br = Invoke-CompileOnly @{ 'broken' = (Join-Path $fixtureRoot 'broken.ps1') } 'broken'
    Assert-True ((@($br.Errors) -join ' ') -match 'does not parse') 'non-parsing script rejected with parse message'

    # -----------------------------------------------------------------------
    Enter-Section '6. Interior helpers execute in dispatched chains'
    # -----------------------------------------------------------------------
    $hp = Invoke-CompileOnly @{ 'helper' = (Join-Path $fixtureRoot 'helper.ps1') } 'helper'
    Assert-True (@($hp.Errors).Count -eq 0) 'helper processor compiles' ($hp.Errors -join '; ')

    $run = Invoke-Plan -Items @([pscustomobject]@{ Value = 21 }, [pscustomobject]@{ Value = 5 }) -Plan $hp.Plan
    Assert-True (@($run.Errors).Count -eq 0) 'dispatch clean' ($run.Errors -join '; ')
    Assert-True ($run.Results[0].Doubled -eq 42) 'helper executed: 21 → 42' "got $($run.Results[0].Doubled)"
    Assert-True ($run.Results[1].Doubled -eq 10) 'helper executed: 5 → 10'
    Assert-True ($run.Results[0].Value -eq 21) 'input properties preserved through copy'
}
finally
{
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ colonel-validation: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
