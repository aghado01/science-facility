#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Unit tests for tools/rs.dev.signatures.psm1.

.DESCRIPTION
    Developer tooling, but AST walking has real edge cases, so it gets the house
    harness like everything else.

    Coverage:
      1. Declaration forms — Script param block / Function / ClassMethod
      2. Defaults — DefaultText as written; HasDefault distinguishes `$x` from
         `$x = $null` (the null-sentinel distinction reflection cannot express)
      3. Attributes — Mandatory (both `Mandatory` and `Mandatory = $true` forms),
         Position, switch, Alias, ValidateSet
      4. Nesting — interior helpers detected at any depth; -ExcludeNested
      5. Facts — CmdletBinding, OutputType, dynamicparam presence
      6. Filtering — -Name wildcard, -ExcludeClassMethods
      7. -Command parameter set against a loaded function
      8. Broken input — parse errors warn, never throw
      9. Live regression — Invoke-Plan's `$MaxWorkers = $null` is reported, the
         case that motivated the module (rs.core.internals could not see it)

.NOTES
    Run from any directory:
        & "$PSScriptRoot\rs.dev.signatures.tests.ps1"
#>

$modulePath = Join-Path $PSScriptRoot '..\rs.dev.signatures.psm1'
Import-Module $modulePath -Force

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
    Assert-True ($Actual -eq $Expected) $Label "expected '$Expected', got '$Actual'"
}

# ---------------------------------------------------------------------------
# Fixture — every declaration form in one file
# ---------------------------------------------------------------------------
$fixtureDir = Join-Path ([IO.Path]::GetTempPath()) "rs-sig-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null

$scriptShaped = @'
param(
    [Parameter(Position = 0)]
    [object]$Item,
    [Parameter(Position = 1)]
    [hashtable]$Config = @{}
)
$x = 1
'@
$scriptFile = Join-Path $fixtureDir 'proc-shaped.ps1'
[IO.File]::WriteAllText($scriptFile, $scriptShaped)

$mixed = @'
<#
.SYNOPSIS
    Does a thing.
#>
function Get-Thing
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Required,

        [Parameter(Mandatory = $true, Position = 2)]
        [Alias('Alt', 'Second')]
        [string] $AlsoRequired,

        [nullable[int]] $Sentinel = $null,

        [int] $Plain = 7,

        [ValidateSet('a', 'b')]
        [string] $Choice,

        [switch] $Flag
    )

    function _InteriorHelper
    {
        param([string] $Inner = 'deep')
        $Inner
    }

    if ($true)
    {
        function _DeeperHelper { param([int] $N) $N }
    }

    _InteriorHelper
}

function Invoke-Dyn
{
    [CmdletBinding()]
    param([string] $Base)
    DynamicParam { }
    process { }
}

class Widget
{
    [string] $Name

    Widget([string] $name) { $this.Name = $name }

    [string] Describe([int] $Verbosity, [string] $Prefix) { return $this.Name }

    [void] Reset() { }
}
'@
$mixedFile = Join-Path $fixtureDir 'mixed.psm1'
[IO.File]::WriteAllText($mixedFile, $mixed)

$broken = @"
function Broken-Thing
{
    param([string] `$A)
    if (`$true) {
"@
$brokenFile = Join-Path $fixtureDir 'broken.ps1'
[IO.File]::WriteAllText($brokenFile, $broken)

Write-Host '============================================================' -ForegroundColor Yellow
Write-Host ' rs.dev.signatures.tests.ps1' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow

try
{
    # =======================================================================
    Enter-Section '1. Declaration forms'
    # =======================================================================
    $scriptSig = @(Get-FunctionSignature -Path $scriptFile)
    Assert-Equal $scriptSig.Count 1 'script param block yields exactly one record'
    Assert-Equal $scriptSig[0].Kind 'Script' 'kind = Script (no function wrapper)'
    Assert-Equal $scriptSig[0].Name 'proc-shaped' 'script name = file base name'
    Assert-Equal $scriptSig[0].ParameterCount 2 'script params counted'

    $all = @(Get-FunctionSignature -Path $mixedFile)
    Assert-True (@($all | Where-Object Kind -eq 'Function').Count -ge 2) 'functions found'
    Assert-True (@($all | Where-Object Kind -eq 'ClassMethod').Count -eq 3) 'class methods found (ctor + 2)' "got $(@($all | Where-Object Kind -eq 'ClassMethod').Count)"
    Assert-True ($null -eq ($all | Where-Object Kind -eq 'Script')) 'no phantom Script record when file has no top-level param block'

    $thing = $all | Where-Object { $_.Name -eq 'Get-Thing' }
    Assert-True ($null -ne $thing) 'Get-Thing located'

    # =======================================================================
    Enter-Section '2. Defaults — the capability reflection lacks'
    # =======================================================================
    $byName = @{}
    foreach ($p in $thing.Parameters) { $byName[$p.Name] = $p }

    Assert-True ($byName['Sentinel'].HasDefault) 'null-sentinel param HAS a default'
    Assert-Equal $byName['Sentinel'].DefaultText '$null' 'null-sentinel DefaultText is $null (as written)'
    Assert-True (-not $byName['Choice'].HasDefault) 'param with no default: HasDefault false'
    Assert-True ($null -eq $byName['Choice'].DefaultText) 'param with no default: DefaultText null'
    Assert-Equal $byName['Plain'].DefaultText '7' 'literal default captured'
    Assert-Equal $scriptSig[0].Parameters[1].DefaultText '@{}' 'expression default captured as written'

    # =======================================================================
    Enter-Section '3. Attributes'
    # =======================================================================
    Assert-True ($byName['Required'].Mandatory) 'Mandatory (bare form) detected'
    Assert-True ($byName['AlsoRequired'].Mandatory) 'Mandatory = $true (explicit form) detected'
    Assert-True (-not $byName['Plain'].Mandatory) 'non-mandatory param not flagged'
    Assert-Equal $byName['AlsoRequired'].Position '2' 'Position captured'
    Assert-True ($byName['Flag'].IsSwitch) 'switch param flagged'
    Assert-True ('Alt' -in $byName['AlsoRequired'].Aliases) 'alias captured'
    Assert-True ('ValidateSet' -in $byName['Choice'].Attributes) 'validation attribute captured'
    Assert-Equal $byName['Sentinel'].Type 'nullable[int]' 'declared type text preserved'

    # =======================================================================
    Enter-Section '4. Nesting'
    # =======================================================================
    $interior = $all | Where-Object { $_.Name -eq '_InteriorHelper' }
    $deeper = $all | Where-Object { $_.Name -eq '_DeeperHelper' }
    Assert-True ($null -ne $interior) 'interior helper found'
    Assert-True ($interior.IsNested) 'interior helper marked nested'
    Assert-True ($null -ne $deeper) 'helper nested inside an if-block found'
    Assert-True ($deeper.IsNested) 'deeper helper marked nested (ancestor walk, not just grandparent)'
    Assert-True (-not $thing.IsNested) 'top-level function not marked nested'

    $noNested = @(Get-FunctionSignature -Path $mixedFile -ExcludeNested)
    Assert-True (@($noNested | Where-Object IsNested).Count -eq 0) '-ExcludeNested drops interior helpers'
    Assert-True (@($noNested | Where-Object { $_.Name -eq 'Get-Thing' }).Count -eq 1) '-ExcludeNested keeps top-level functions'

    # =======================================================================
    Enter-Section '5. Scriptblock facts'
    # =======================================================================
    Assert-True ($thing.IsAdvanced) 'CmdletBinding detected'
    Assert-True ('[pscustomobject]' -in $thing.OutputType) 'OutputType captured'
    Assert-True (-not $thing.HasDynamicParam) 'no dynamicparam on a plain function'
    $dyn = $all | Where-Object { $_.Name -eq 'Invoke-Dyn' }
    Assert-True ($dyn.HasDynamicParam) 'dynamicparam block detected'
    Assert-Equal $thing.Synopsis 'Does a thing.' 'comment-based help synopsis harvested'
    Assert-True ($thing.Line -gt 0) 'line number recorded'
    Assert-True ($thing.Location -match 'mixed\.psm1:\d+') 'Location is file:line'

    # =======================================================================
    Enter-Section '6. Filtering'
    # =======================================================================
    $filtered = @(Get-FunctionSignature -Path $mixedFile -Name 'Get-*')
    Assert-True ($filtered.Count -eq 1 -and $filtered[0].Name -eq 'Get-Thing') '-Name wildcard filters'
    $noClass = @(Get-FunctionSignature -Path $mixedFile -ExcludeClassMethods)
    Assert-True (@($noClass | Where-Object Kind -eq 'ClassMethod').Count -eq 0) '-ExcludeClassMethods drops class members'

    $widget = $all | Where-Object { $_.Kind -eq 'ClassMethod' -and $_.Name -eq 'Describe' }
    Assert-Equal $widget.Class 'Widget' 'class method carries owning class'
    Assert-Equal $widget.ParameterCount 2 'class method params counted'
    Assert-True ('string' -in $widget.OutputType) 'class method return type captured'
    $reset = $all | Where-Object { $_.Kind -eq 'ClassMethod' -and $_.Name -eq 'Reset' }
    Assert-True ('void' -in $reset.OutputType) 'void return captured'

    # =======================================================================
    Enter-Section '7. -Command parameter set'
    # =======================================================================
    # Resolution happens inside the module's session state, so a script-local
    # function would be invisible here — use an exported command (documented
    # caveat: for script-local functions, pass -Path instead).
    $cmdSig = @(Get-FunctionSignature -Command 'Get-FunctionSignature')
    Assert-Equal $cmdSig.Count 1 '-Command yields one record'
    Assert-Equal $cmdSig[0].Name 'Get-FunctionSignature' '-Command resolves the name'
    Assert-Equal (@($cmdSig[0].Parameters | Where-Object Name -eq 'Name')[0].DefaultText) "'*'" '-Command reports declared default'
    Assert-True ($cmdSig[0].IsAdvanced) '-Command reports CmdletBinding'

    # =======================================================================
    Enter-Section '8. Broken input is non-fatal'
    # =======================================================================
    $threw = $false
    $brokenSig = $null
    try { $brokenSig = @(Get-FunctionSignature -Path $brokenFile -WarningAction SilentlyContinue) }
    catch { $threw = $true }
    Assert-True (-not $threw) 'parse errors do not throw'
    Assert-True (@($brokenSig | Where-Object { $_.Name -eq 'Broken-Thing' }).Count -eq 1) 'error-recovering parser still yields the function'

    # =======================================================================
    Enter-Section '9. Live regression — the case that motivated the module'
    # =======================================================================
    # rs.core.internals cannot see this: ParameterMetadata has no DefaultValue.
    Import-Module (Join-Path $PSScriptRoot '..\..\reposnapshot-v3\rs.core.colonel.v2.psm1') -Force -WarningAction SilentlyContinue
    $plan = Get-FunctionSignature -Command 'Invoke-Plan'
    $mw = @($plan.Parameters | Where-Object Name -eq 'MaxWorkers')[0]
    Assert-True ($mw.HasDefault) 'Invoke-Plan MaxWorkers HAS a declared default'
    Assert-Equal $mw.DefaultText '$null' 'MaxWorkers default is the $null sentinel (Policy=Auto trigger)'
    Assert-Equal (@($plan.Parameters | Where-Object Name -eq 'ReservedCores')[0].DefaultText) '2' 'ReservedCores default read from AST'
    Assert-True ((Get-Command Invoke-Plan).Parameters['MaxWorkers'].PSObject.Properties['DefaultValue'] -eq $null) `
        'reflection still exposes no DefaultValue member (why this module exists)'

    # Formatter round-trip
    $text = $plan | Format-FunctionSignature
    Assert-True ($text -match '\$MaxWorkers = \$null') 'formatter renders the default as declared'
    Assert-True ($text -notmatch '  $') 'formatter leaves no trailing whitespace'
}
finally
{
    Remove-Item $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "═══ rs.dev.signatures: $($script:Passed) passed, $($script:Failed) failed ═══" -ForegroundColor $color
if ($script:Failed -gt 0) { exit 1 }
