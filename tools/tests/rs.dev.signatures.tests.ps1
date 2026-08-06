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
    # null, not '' — a [string] param would coerce the absent case to empty
    # (the GetParentPath trap; see New-SignatureRecord).
    Assert-True ($null -eq ($all | Where-Object { $_.Name -eq 'Invoke-Dyn' }).Synopsis) 'function without help reports null synopsis, not empty string'
    Assert-True ($null -eq $thing.Class) 'non-class function reports null Class, not empty string'
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
    Enter-Section '7b. -ScriptText parameter set (the processor-wrappable mode)'
    # =======================================================================
    # A chain item carries Content that upstream mutators already rewrote, so a
    # survey processor must read those bytes, never re-read the file. Records
    # must be identical to the -Path route apart from the source label.
    $mixedText = [IO.File]::ReadAllText($mixedFile)
    $viaText = @(Get-FunctionSignature -ScriptText $mixedText -SourceName $mixedFile)
    $viaPath = @(Get-FunctionSignature -Path $mixedFile)
    Assert-Equal $viaText.Count $viaPath.Count '-ScriptText yields the same record count as -Path'
    $tJson = ($viaText | Select-Object * -ExcludeProperty File, Location | ConvertTo-Json -Depth 8 -Compress)
    $pJson = ($viaPath | Select-Object * -ExcludeProperty File, Location | ConvertTo-Json -Depth 8 -Compress)
    Assert-True ($tJson -eq $pJson) '-ScriptText records identical to -Path (apart from source label)'

    $scriptText = [IO.File]::ReadAllText($scriptFile)
    $textScript = @(Get-FunctionSignature -ScriptText $scriptText -SourceName 'src/proc-shaped.ps1')
    Assert-Equal $textScript[0].Kind 'Script' '-ScriptText finds the script param block'
    Assert-Equal $textScript[0].Name 'proc-shaped' 'script name derived from SourceName'
    Assert-Equal $textScript[0].File 'src/proc-shaped.ps1' 'SourceName stamped as File (artifact-facing path)'
    Assert-True ($textScript[0].Location -match '^src/proc-shaped\.ps1:\d+$') 'Location built from SourceName'
    Assert-Equal $textScript[0].Parameters[1].DefaultText '@{}' '-ScriptText reports defaults'

    # Mutated content surveys as mutated — the reason disk re-reads are wrong.
    # STRUCTURAL EXTRACTION IS COMMENT-INVARIANT: comments are not executable
    # code, so they contribute nothing to declarations, signatures, types or
    # defaults. This is what lets the survey sit in the read-only tail (after all
    # content mutators) rather than needing to run early — the position that also
    # keeps its span anchors pointing at the bytes the payload actually ships.
    # Self-contained strip so the module keeps its no-reposnapshot dependency.
    $stripped = ($mixedText -replace '(?s)<#.*?#>', '') -replace '(?m)^\s*#(?!Requires)[^\r\n]*\r?\n', ''
    $preStrip = @(Get-FunctionSignature -ScriptText $mixedText -SourceName 'm.psm1')
    $postStrip = @(Get-FunctionSignature -ScriptText $stripped -SourceName 'm.psm1')

    Assert-Equal $postStrip.Count $preStrip.Count 'comment-invariant: same declaration count after stripping'
    $structural = 'Kind', 'Name', 'Class', 'IsNested', 'IsAdvanced', 'HasDynamicParam', 'ParameterCount'
    $preJson = ($preStrip | Select-Object $structural | ConvertTo-Json -Depth 6 -Compress)
    $postJson = ($postStrip | Select-Object $structural | ConvertTo-Json -Depth 6 -Compress)
    Assert-True ($preJson -eq $postJson) 'comment-invariant: structural fields byte-identical after stripping'
    $preParams = ($preStrip.Parameters | ConvertTo-Json -Depth 6 -Compress)
    $postParams = ($postStrip.Parameters | ConvertTo-Json -Depth 6 -Compress)
    Assert-True ($preParams -eq $postParams) 'comment-invariant: parameter surfaces (types, defaults) unchanged'
    Assert-True ($stripped.Length -lt $mixedText.Length) 'the strip actually removed content (invariance is not vacuous)'

    # Only DOCUMENTATION is lost — a separate concern that must not ride the
    # survey element (a survey is an index; prose is content).
    $noHelp = $postStrip | Where-Object { $_.Name -eq 'Get-Thing' }
    Assert-True ($null -eq $noHelp.Synopsis) 'stripping costs only the synopsis (documentation, not structure)'

    $emptyText = @(Get-FunctionSignature -ScriptText '' -SourceName 'empty.ps1')
    Assert-Equal $emptyText.Count 0 'empty text yields no records (no throw)'

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

    # =======================================================================
    Enter-Section '9b. Span anchors (survey → byte-span fetch)'
    # =======================================================================
    $asciiText = "function Alpha { param([int] `$A = 1) }`nfunction Beta { param([string] `$B) }`n"
    $asciiSigs = @(Get-FunctionSignature -ScriptText $asciiText -SourceName 'a.ps1')
    $alpha = $asciiSigs | Where-Object Name -eq 'Alpha'

    Assert-True ($null -ne $alpha.Span) 'record carries a Span anchor'
    Assert-Equal $alpha.Span.CharStart 0 'CharStart is 0-based'
    Assert-Equal $alpha.Span.CharLength ($alpha.Span.CharEnd - $alpha.Span.CharStart) 'CharLength = CharEnd - CharStart (end exclusive)'
    Assert-Equal $asciiText.Substring($alpha.Span.CharStart, $alpha.Span.CharLength) 'function Alpha { param([int] $A = 1) }' `
        'char span round-trips to the declaration text'
    Assert-Equal $alpha.Span.ByteStart $alpha.Span.CharStart 'pure ASCII: ByteStart == CharStart'
    Assert-Equal $alpha.Span.SpanBytes $alpha.Span.CharLength 'pure ASCII: SpanBytes == CharLength'

    $beta = $asciiSigs | Where-Object Name -eq 'Beta'
    Assert-True ($beta.Span.CharStart -gt $alpha.Span.CharEnd - 1) 'second declaration anchored after the first'

    # Multibyte: the two offset families DIVERGE, which is why both are reported.
    # This is not hypothetical for this repo — its docstrings use em-dashes and
    # box-drawing, so source files are routinely non-ASCII.
    $mbText = "# héllo — ünicode ✓ emoji 🚀`nfunction Gamma { param([int] `$N = 1) }`n"
    $gamma = Get-FunctionSignature -ScriptText $mbText -SourceName 'mb.ps1' -Name 'Gamma'
    $declText = 'function Gamma { param([int] $N = 1) }'

    Assert-True ($gamma.Span.ByteStart -gt $gamma.Span.CharStart) 'multibyte: ByteStart exceeds CharStart'
    Assert-Equal $mbText.Substring($gamma.Span.CharStart, $gamma.Span.CharLength) $declText 'multibyte: char span still round-trips in memory'
    $mbBytes = [System.Text.Encoding]::UTF8.GetBytes($mbText)
    Assert-Equal ([System.Text.Encoding]::UTF8.GetString($mbBytes, $gamma.Span.ByteStart, $gamma.Span.SpanBytes)) $declText `
        'multibyte: byte span round-trips against UTF-8 bytes'
    Assert-True (([System.Text.Encoding]::UTF8.GetString($mbBytes, $gamma.Span.CharStart, $gamma.Span.CharLength)) -ne $declText) `
        'multibyte: using char offsets as byte offsets yields the WRONG slice (the conflation this guards)'

    # Class methods and script param blocks are anchored too.
    $allSpans = @(Get-FunctionSignature -Path $mixedFile)
    Assert-True (@($allSpans | Where-Object { $null -eq $_.Span }).Count -eq 0) 'every kind carries a Span'
    $describe = $allSpans | Where-Object { $_.Kind -eq 'ClassMethod' -and $_.Name -eq 'Describe' }
    Assert-True ($describe.Span.SpanBytes -gt 0) 'class method span is non-empty'

    # -Command cannot derive bytes honestly: its extents are file-relative while
    # only the function's own text is in hand. Absent beats wrong.
    $cmdSpan = (Get-FunctionSignature -Command 'Get-FunctionSignature').Span
    Assert-True ($cmdSpan.CharStart -ge 0) '-Command still reports char offsets'
    Assert-True ($null -eq $cmdSpan.ByteStart) '-Command reports NULL byte offsets rather than guessing'
    Assert-True ($null -eq $cmdSpan.SpanBytes) '-Command reports null SpanBytes'

    # =======================================================================
    Enter-Section '10. Compare-ParameterSurface'
    # =======================================================================
    $cmpFile = Join-Path $fixtureDir 'cmp.psm1'
    [IO.File]::WriteAllText($cmpFile, @'
function Left  { param([string] $Only1, [int] $Both = 1, [string] $Typed, [int] $Mand) }
function Right { param([string] $Only2, [int] $Both = 2, [int] $Typed, [Parameter(Mandatory)][int] $Mand) }
'@)
    $left = Get-FunctionSignature -Path $cmpFile -Name 'Left'
    $right = Get-FunctionSignature -Path $cmpFile -Name 'Right'
    $cmp = Compare-ParameterSurface -Reference $left -Difference $right

    Assert-True ('Only1' -in $cmp.OnlyInReference) 'reference-only param partitioned'
    Assert-True ('Only2' -in $cmp.OnlyInDifference) 'difference-only param partitioned'
    Assert-True ('Both' -in $cmp.Shared) 'shared param listed'
    Assert-True (-not $cmp.IsDisjoint) 'IsDisjoint false when surfaces overlap'
    Assert-True ($cmp.HasConflicts) 'conflicts detected'

    $byConflict = @{}
    foreach ($c in $cmp.Conflicts) { $byConflict[$c.Name] = $c }
    Assert-True ('DefaultMismatch' -in $byConflict['Both'].Reasons) 'differing defaults flagged'
    Assert-Equal $byConflict['Both'].ReferenceDefault '1' 'conflict carries reference default'
    Assert-Equal $byConflict['Both'].DifferenceDefault '2' 'conflict carries difference default'
    Assert-True ('TypeMismatch' -in $byConflict['Typed'].Reasons) 'differing types flagged'
    Assert-True ('MandatoryMismatch' -in $byConflict['Mand'].Reasons) 'differing mandatory-ness flagged'

    # Accepts command names as well as records.
    $byName = Compare-ParameterSurface -Reference 'Compile-Plan' -Difference 'Invoke-Plan'
    Assert-Equal $byName.Reference 'Compile-Plan' 'string input resolves via Get-Command'
    $threw = $false
    try { Compare-ParameterSurface -Reference 42 -Difference 'Invoke-Plan' } catch { $threw = $true }
    Assert-True $threw 'unusable input throws rather than comparing nothing'

    # LIVE GUARD: ingest routes bound params by withholding the sibling's whole
    # surface, and its DynamicParam merge resolves collisions "Compile-Plan wins".
    # While these two surfaces stay disjoint that policy is never exercised. If
    # colonel ever adds a name to BOTH, this fails — telling you ingest's routing
    # silently changed meaning, which is precisely how the hardcoded-list bug bit.
    Assert-True $byName.IsDisjoint `
        'Compile-Plan / Invoke-Plan surfaces are disjoint (ingest routing is unambiguous)' `
        "shared: $($byName.Shared -join ', ')"
    Assert-True (-not $byName.HasConflicts) 'no same-name conflicts across the two colonel targets'

    # Common params never leak in — signatures are AST-declared, not runtime.
    Assert-True ('Verbose' -notin $byName.OnlyInReference -and 'Verbose' -notin $byName.OnlyInDifference) `
        'common parameters absent from AST-derived surfaces'
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
    Remove-Item $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "═══ rs.dev.signatures: $($script:Passed) passed, $($script:Failed) failed ═══" -ForegroundColor $color
if ($script:Failed -gt 0) { exit 1 }
