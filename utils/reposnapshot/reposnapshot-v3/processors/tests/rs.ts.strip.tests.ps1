#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/rs.ts.strip.ps1.
#>

$processorPath = Join-Path $PSScriptRoot '..\rs.ts.strip.ps1'
. (Join-Path $PSScriptRoot '_helpers.ps1')

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

function Invoke-Processor ([object]$Item, [hashtable]$Config = @{})
{
    if ($Item -is [string]) { $Item = [pscustomobject]@{ Content = $Item } }
    & $processorPath $Item $Config
}

$fixture = @'
/// <reference path="./types.d.ts" />
/// <amd-module name="mod" />
/**
 * TSDoc doc string
 */
function foo(): void {
    // isolated
    const url = "http://example.com/path";
    const x = 1; // trailing inline
}
'@

$langRoot = Join-Path $PSScriptRoot '..\..\..\tests\languages\typescript'

Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' rs.ts.strip.tests.ps1' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow

try
{
    Enter-Section '1. FrontMatter + mask + default ops'
    $r = Invoke-Processor -Item $fixture
    Assert-True ($r.Processing[0].Implementation -eq 'rs.ts.strip') 'Implementation is rs.ts.strip'
    Assert-True ($r.Content -match '/// <reference path="./types.d.ts" />') 'Default: triple-slash reference kept'
    Assert-True ($r.Content -match '/// <amd-module name="mod" />') 'Default: amd-module directive kept'
    Assert-True ($r.Content -notmatch 'TSDoc doc string') 'Default: TSDoc stripped'
    Assert-True ($r.Content -notmatch 'isolated') 'Default: LineComment stripped'
    Assert-True ($r.Content -match 'trailing inline') 'Default: InlineComment kept'
    Assert-True ($r.Content.Contains('"http://example.com/path"')) 'Mask: // inside string kept'
    Assert-True ($r.Content -match 'function foo') 'Default: code preserved'
    Assert-True ($r.Content -notmatch ([char]0x01)) 'Mask: no sentinel leaked'

    $rPlain = Invoke-Processor -Item "/// just a comment`nconst x = 1;`n"
    Assert-True ($rPlain.Content -notmatch 'just a comment') 'non-directive /// is a LineComment, stripped'
    Assert-True ($rPlain.Content -match 'const x = 1;') 'code after non-directive /// kept'

    Enter-Section '2. tests/languages/typescript battery'
    Assert-True (Test-Path -LiteralPath $langRoot) 'typescript specimen dir exists' $langRoot
    $tsFiles = @(Get-ChildItem -LiteralPath $langRoot -File | Where-Object { $_.Extension -in '.ts', '.tsx', '.mts', '.cts' -or $_.Name.EndsWith('.d.ts') })
    Assert-True ($tsFiles.Count -ge 4) "at least four TS specimens ($($tsFiles.Count))"

    foreach ($f in $tsFiles)
    {
        $src = [IO.File]::ReadAllText($f.FullName)
        $out = Invoke-Processor -Item $src
        Assert-True ($out.Content -notmatch ([char]0x01)) "$($f.Name): no sentinel leaked"
        Assert-True ($out.Content -match 'export |import |interface |function |class |type ') `
            "$($f.Name): code tokens survived"
    }

    $linter = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'linter-ts.ts')))
    Assert-True ($linter.Content -notmatch 'Detects unbalanced delimiters') 'linter-ts.ts: file JSDoc stripped'
    Assert-True ($linter.Content -notmatch 'WHEN TO USE') 'linter-ts.ts: block comment stripped'
    Assert-True ($linter.Content -match 'import \* as fs') 'linter-ts.ts: import kept'

    $dts = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'safe-shell.d.ts')))
    Assert-True ($dts.Content -notmatch 'Type definitions for safe-shell module') 'safe-shell.d.ts: file JSDoc stripped'
    Assert-True ($dts.Content -match 'export interface ShellCommandArgs') 'safe-shell.d.ts: interface kept'
    Assert-True ($dts.Content -match 'command: string') 'safe-shell.d.ts: field kept'

    $shell = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'safe-shell.ts')))
    Assert-True ($shell.Content -notmatch 'Gargoyle-resistant shell access') 'safe-shell.ts: file JSDoc stripped'
    Assert-True ($shell.Content -match 'export ') 'safe-shell.ts: export survived'

    $psLinter = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'linter-ps.ts')))
    Assert-True ($psLinter.Content -notmatch 'WHEN TO USE PS-LINTER') 'linter-ps.ts: block comment stripped'
    Assert-True ($psLinter.Content -match 'import \{ spawnSync \}') 'linter-ps.ts: import kept'

    $bridge = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'supervisor-bridge.ts')))
    Assert-True ($bridge.Content -notmatch 'Supervisor Bridge - JSON-RPC') 'supervisor-bridge.ts: file JSDoc stripped'
    Assert-True ($bridge.Content -match 'export ') 'supervisor-bridge.ts: export survived'
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Yellow
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  Passed: $($script:Passed)   Failed: $($script:Failed)" -ForegroundColor $color
Write-Host '============================================================' -ForegroundColor Yellow
if ($script:Failed -gt 0) { exit 1 }
