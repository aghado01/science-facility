#Requires -Version 7.6
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for processors/rs.js.strip.ps1.
#>

$processorPath = Join-Path $PSScriptRoot '..\rs.js.strip.ps1'
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

function Assert-Equal ($Actual, $Expected, [string]$Label)
{
    Assert-True ($Actual -eq $Expected) $Label "expected $(([string]$Expected).Length -le 60 ? "'$Expected'" : "(value)"), got $(([string]$Actual).Length -le 60 ? "'$Actual'" : "(value)")"
}

function Invoke-Processor ([object]$Item, [hashtable]$Config = @{})
{
    if ($Item -is [string]) { $Item = [pscustomobject]@{ Content = $Item } }
    & $processorPath $Item $Config
}

function Invoke-ProcessorRaw ([object]$Item, [hashtable]$Config = @{})
{
    & $processorPath $Item $Config
}

$fixture = @'
#!/usr/bin/env node
/* standalone block
   second line */
/**
 * JSDoc doc string
 */
function foo() {
    // block line one
    // block line two
    const url = "http://example.com/path";
    const re = /https?:\/\//;
    const t = `template with // slashes`;
    const x = 1; // trailing inline
    try { bar(); } catch { /* intentionally empty */ }
    // isolated single line
}
'@

$langRoot = Join-Path $PSScriptRoot '..\..\..\tests\languages\javascript'

Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' rs.js.strip.tests.ps1' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow

try
{
    Enter-Section '1. Item unpacking'
    $rStr = Invoke-ProcessorRaw -Item $fixture
    $rPsco = Invoke-Processor -Item ([pscustomobject]@{ Content = $fixture; Id = 'p1'; Path = 'y.js' })
    Assert-True ($rStr -is [string]) 'String item: bare string in → bare string out'
    Assert-True ($rStr -notmatch 'standalone block') 'String item: stripping applied'
    Assert-True ($rPsco -is [pscustomobject]) 'PSCustomObject item: returns pscustomobject'
    Assert-Equal $rPsco.Id 'p1' 'PSCustomObject item: Id propagated'
    Assert-Equal $rPsco.Processing[0].Processor 'rs.js.strip' 'Processing record names the processor'
    Assert-Equal $rPsco.Processing[0].Implementation 'rs.js.strip' 'Implementation is rs.js.strip'

    Enter-Section '2. Default ops + mask lens'
    $rDef = Invoke-Processor -Item $fixture
    Assert-True ($rDef.Content -match '#!/usr/bin/env node') 'Default: shebang kept'
    Assert-True ($rDef.Content -notmatch 'standalone block') 'Default: standalone BlockComment stripped'
    Assert-True ($rDef.Content -notmatch 'JSDoc doc string') 'Default: DocString stripped'
    Assert-True ($rDef.Content -notmatch 'block line one') 'Default: CommentBlock stripped'
    Assert-True ($rDef.Content -notmatch 'isolated single line') 'Default: LineComment stripped'
    Assert-True ($rDef.Content -match 'trailing inline') 'Default: InlineComment kept'
    Assert-True ($rDef.Content -match 'intentionally empty') 'Default: InteriorComment kept'
    Assert-True ($rDef.Content -match 'function foo') 'Default: code preserved'
    Assert-True ($rDef.Content.Contains('"http://example.com/path"')) 'Mask: // inside double-quoted string kept'
    Assert-True ($rDef.Content.Contains('/https?:\/\//')) 'Mask: // inside regex literal kept'
    Assert-True ($rDef.Content.Contains('`template with // slashes`')) 'Mask: // inside template kept'
    Assert-True ($rDef.Content -notmatch ([char]0x01)) 'Mask: no sentinel leaked into payload'

    Enter-Section '3. Selective ops'
    $rB = Invoke-Processor -Item $fixture -Config @{ Operations = @('block-comments') }
    Assert-True ($rB.Content -notmatch 'standalone block') 'block-comments: standalone block stripped'
    Assert-True ($rB.Content -match 'JSDoc doc string') 'block-comments: DocString kept'
    $rD = Invoke-Processor -Item $fixture -Config @{ Operations = @('doc-strings') }
    Assert-True ($rD.Content -notmatch 'JSDoc doc string') 'doc-strings: JSDoc stripped'
    Assert-True ($rD.Content -match 'standalone block') 'doc-strings: BlockComment kept'
    $rI = Invoke-Processor -Item $fixture -Config @{ Operations = @('inline-comments') }
    Assert-True ($rI.Content -notmatch 'trailing inline') 'inline-comments: trailing stripped'
    Assert-True ($rI.Content -match 'const x = 1;') 'inline-comments: code on that line preserved'

    Enter-Section '4. tests/languages/javascript battery'
    Assert-True (Test-Path -LiteralPath $langRoot) 'javascript specimen dir exists' $langRoot
    $jsFiles = @(Get-ChildItem -LiteralPath $langRoot -File | Where-Object { $_.Extension -in '.js', '.mjs', '.cjs', '.jsx' })
    Assert-True ($jsFiles.Count -ge 3) "at least three JS specimens ($($jsFiles.Count))"

    foreach ($f in $jsFiles)
    {
        $src = [IO.File]::ReadAllText($f.FullName)
        $r = Invoke-Processor -Item $src
        Assert-True ($r.Content -notmatch ([char]0x01)) "$($f.Name): no sentinel leaked"
        if ($src.StartsWith('#!'))
        {
            Assert-True ($r.Content.StartsWith('#!')) "$($f.Name): shebang kept"
        }
        Assert-True ($r.Content -match 'function |const |import |require\(|export ') `
            "$($f.Name): code tokens survived" 
    }

    $md = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'md-lint.js')))
    Assert-True ($md.Content -notmatch 'markdown STRUCTURE lint') 'md-lint.js: header CommentBlock stripped'
    Assert-True ($md.Content -match "'use strict'") 'md-lint.js: string literal kept'
    Assert-True ($md.Content -match 'function argument') 'md-lint.js: function kept'
    Assert-True ($md.Content -match 'pathToFileURL') 'md-lint.js: import kept'

    $render = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'render.mjs')))
    Assert-True ($render.Content -notmatch 'pig-lane raster tool') 'render.mjs: header CommentBlock stripped'
    Assert-True ($render.Content -match 'function argOf') 'render.mjs: function kept'
    Assert-True ($render.Content -match 'node:fs') 'render.mjs: import specifier kept'

    $tikz = Invoke-Processor -Item ([IO.File]::ReadAllText((Join-Path $langRoot 'tikz-svg.js')))
    Assert-True ($tikz.Content -notmatch 'batch TikZ/tikz-cd') 'tikz-svg.js: header CommentBlock stripped'
    Assert-True ($tikz.Content -match 'async function main') 'tikz-svg.js: function kept'
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
