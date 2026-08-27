#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/rs.py.strip.ps1.
#>

$processorPath = Join-Path $PSScriptRoot '..\rs.py.strip.ps1'
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
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""module docstring removed"""
url = "http://example.com#anchor"
data = """triple-quoted data kept"""
def f():
    """fn docstring removed"""
    return url  # trailing comment kept
# standalone comment removed
# run line one
# run line two
z = 1
'@

$langRoot = Join-Path $PSScriptRoot '..\..\..\tests\languages\python'

Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' rs.py.strip.tests.ps1' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow

try
{
    Enter-Section '1. FrontMatter + mask + default ops'
    $r = Invoke-Processor -Item $fixture
    Assert-True ($r.Processing[0].Implementation -eq 'rs.py.strip') 'Implementation is rs.py.strip'
    Assert-True ($r.Content.StartsWith('#!/usr/bin/env python3')) 'Default: shebang kept'
    Assert-True ($r.Content -match 'coding: utf-8') 'Default: PEP 263 cookie kept'
    Assert-True ($r.Content -notmatch 'module docstring removed') 'Default: module DocString stripped'
    Assert-True ($r.Content -notmatch 'fn docstring removed') 'Default: def DocString stripped'
    Assert-True ($r.Content.Contains('"""triple-quoted data kept"""')) 'Mask: assigned triple kept'
    Assert-True ($r.Content.Contains('"http://example.com#anchor"')) 'Mask: # inside string kept'
    Assert-True ($r.Content -match 'trailing comment kept') 'Default: InlineComment kept'
    Assert-True ($r.Content -notmatch 'standalone comment removed') 'Default: LineComment stripped'
    Assert-True ($r.Content -notmatch 'run line one') 'Default: CommentBlock stripped'
    Assert-True ($r.Content -match 'def f\(\):') 'Default: def kept'
    Assert-True ($r.Content -match 'z = 1') 'Default: assignment kept'
    Assert-True ($r.Content -notmatch ([char]0x01)) 'Mask: no sentinel leaked'

    $rInline = Invoke-Processor -Item $fixture -Config @{ Operations = @('inline-comments') }
    Assert-True ($rInline.Content -notmatch 'trailing comment kept') 'inline-comments: trailing stripped'
    Assert-True ($rInline.Content -match 'return url') 'inline-comments: code on that line preserved'
    Assert-True ($rInline.Content.Contains('"http://example.com#anchor"')) 'inline-comments: # in string still kept'

    Enter-Section '2. tests/languages/python battery'
    Assert-True (Test-Path -LiteralPath $langRoot) 'python specimen dir exists' $langRoot
    $pyFiles = @(Get-ChildItem -LiteralPath $langRoot -File | Where-Object { $_.Extension -in '.py', '.pyw', '.pyi' })
    Assert-True ($pyFiles.Count -ge 5) "at least five Python specimens ($($pyFiles.Count))"

    foreach ($f in $pyFiles)
    {
        $src = [IO.File]::ReadAllText($f.FullName)
        $out = Invoke-Processor -Item $src
        Assert-True ($out.Content -notmatch ([char]0x01)) "$($f.Name): no sentinel leaked"
        Assert-True ($out.Content -match 'def |class |import |from ') `
            "$($f.Name): code tokens survived"
    }

    $init = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot '__init__.py')))
    Assert-True ($init.Content -notmatch 'spcx_viz \(package: mvp\)') '__init__.py: module docstring stripped'
    Assert-True ($init.Content -match 'from \.bootstrap import setup') '__init__.py: import kept'
    Assert-True ($init.Content -notmatch 'NOTE: the headless benchmark') '__init__.py: trailing comment block stripped'

    $cli = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'cli.py')))
    Assert-True ($cli.Content -notmatch 'Locate and invoke the published Spcx CLI') 'cli.py: module docstring stripped'
    Assert-True ($cli.Content -match 'def repo_root') 'cli.py: def kept'
    Assert-True ($cli.Content -match 'def find_spcx_cli') 'cli.py: second def kept'
    Assert-True ($cli.Content -notmatch 'Repo root — derived from this file') 'cli.py: function docstring stripped'

    $boot = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'bootstrap.py')))
    Assert-True ($boot.Content -notmatch 'One-call notebook session setup') 'bootstrap.py: module docstring stripped'
    Assert-True ($boot.Content -match 'def setup') 'bootstrap.py: def kept'

    $bench = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'bench.py')))
    Assert-True ($bench.Content -notmatch 'Headless benchmarking entry point') 'bench.py: module docstring stripped'
    Assert-True ($bench.Content -match 'def main') 'bench.py: def kept'

    $data = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'datasets.py')))
    Assert-True ($data.Content -notmatch 'Loaders for external dataset formats') 'datasets.py: module docstring stripped'
    Assert-True ($data.Content -match 'import |def |class ') 'datasets.py: code survived'

    $shared = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'cli_shared.py')))
    Assert-True ($shared.Content -notmatch 'Shared CLI helpers for notebook-level') 'cli_shared.py: module docstring stripped'
    Assert-True ($shared.Content -match 'def add_dataset_args') 'cli_shared.py: def kept'
    Assert-True ($shared.Content -match 'Synthetic generator name') 'cli_shared.py: help= string kept'
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
