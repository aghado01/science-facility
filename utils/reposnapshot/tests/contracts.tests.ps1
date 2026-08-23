#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Cross-stage contract checks over reposnapshot-v3/contracts/*.contract.json.

.DESCRIPTION
    Every stage declares { stage, in, out } with field registers under named
    shapes. A field entry may carry `from: "<stage>.out.<shape>"` (or
    `<stage>.out.<shape>.<register>` for a nested register one level down,
    e.g. assemble.out.entry.core), meaning it is taken verbatim from that
    upstream shape. This suite is GENERIC — it knows no stage by name:

      1. Every schema parses, names its stage, and has in/out.
      2. Every `from` resolves: the referenced stage exists, the shape exists
         under its out, and the field is a member of it. That is the subset
         relation between a stage's input and its upstream's output, checked
         per field.
      3. Join residues are computed and printed as INFO — for each pair
         (X.out.<shape> referenced by Y.in.<shape>), the fields of X.out.<shape>
         that Y does not carry through to Y.out.<shape>. Those are the fields
         reachable downstream only by joining Y.out ⋈ X.out (the orchestrator
         retains stage outputs). Printed, not asserted: they are facts about
         the pipeline shape, not failures.
      4. Nothing declares a `from` pointing at its own stage.

.NOTES
    Run from any directory:
        & "$PSScriptRoot\contracts.tests.ps1"
#>

$schemaDir = Join-Path $PSScriptRoot '..\reposnapshot-v3\contracts'

# ---------------------------------------------------------------------------
# Minimal assertion framework (house pattern — see colonel-dispatch.tests.ps1)
# ---------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0
$script:Section = ''

function Enter-Section ([string]$Name)
{
    $script:Section = $Name
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

function Write-Info ([string]$Text) { Write-Host "    INFO  $Text" -ForegroundColor DarkGray }

# Field-register helpers — a shape is a hashtable of name → entry; entries are
# hashtables (or, for `exclude`, a plain array, which is not a shape).
function Get-ShapeFields ([object]$Shape)
{
    if ($Shape -is [System.Collections.IDictionary]) { return @($Shape.Keys | Where-Object { $_ -ne '…' }) }
    return @()
}

# Resolve a `from` reference to the upstream shape it names. Three segments
# (<stage>.out.<shape>) or four (<stage>.out.<shape>.<register>) — the fourth
# names a nested register one level down (e.g. assemble.out.entry.core), the
# same one level the walk below allows. Returns @{ Stage; ShapeKey; Shape } or
# a @{ Why } explaining the failure.
function Resolve-OutShape ([hashtable]$Contracts, [string]$Ref)
{
    $parts = $Ref -split '\.'
    if (($parts.Count -ne 3 -and $parts.Count -ne 4) -or $parts[1] -ne 'out') { return @{ Why = "malformed — expected <stage>.out.<shape>[.<register>]" } }
    if (-not $Contracts.ContainsKey($parts[0])) { return @{ Why = "no contract for stage '$($parts[0])'" } }
    if (-not $Contracts[$parts[0]].out.ContainsKey($parts[2])) { return @{ Why = "'$($parts[0]).out.$($parts[2])' shape does not exist" } }
    $shape = $Contracts[$parts[0]].out[$parts[2]]
    $key = $parts[2]
    if ($parts.Count -eq 4)
    {
        if ($shape -isnot [System.Collections.IDictionary] -or -not $shape.ContainsKey($parts[3])) { return @{ Why = "'$Ref' register does not exist under $($parts[0]).out.$($parts[2])" } }
        $reg = $shape[$parts[3]]
        # A register is either a FIELD REGISTER (name → descriptor) or a NAME
        # LIST (assemble's carried / exclude tiers — names only, no per-field
        # notes). Normalize the list form so membership resolves the same way.
        if ($reg -is [System.Collections.IDictionary]) { $shape = $reg }
        elseif ($reg -is [System.Collections.IEnumerable] -and $reg -isnot [string])
        {
            $norm = @{}
            foreach ($n in $reg) { $norm[[string]$n] = @{ type = 'name-list entry' } }
            $shape = $norm
        }
        else { return @{ Why = "'$Ref' register does not exist under $($parts[0]).out.$($parts[2])" } }
        $key = "$($parts[2]).$($parts[3])"
    }
    return @{ Stage = $parts[0]; ShapeKey = $key; Shape = $shape }
}

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. Every contract parses and names its stage'
    # -----------------------------------------------------------------------
    # *.contract.json only — contracts/ also holds payload declarations that are
    # not stage contracts (container.spec.jsonc) and must not be parsed as one.
    $files = @(Get-ChildItem -LiteralPath $schemaDir -Filter '*.contract.json' | Sort-Object Name)
    Assert-True ($files.Count -ge 1) "contract files found under contracts/" "got $($files.Count)"

    $contracts = @{}
    foreach ($f in $files)
    {
        $c = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable
        $expected = $f.Name -replace '\.contract\.json$', ''
        Assert-True ($c.stage -eq $expected) "$($f.Name): stage = '$expected'" "got '$($c.stage)'"
        Assert-True ($c.ContainsKey('in') -and $c.ContainsKey('out')) "$($f.Name): has in and out"
        $contracts[$c.stage] = $c
    }

    # -----------------------------------------------------------------------
    Enter-Section '2. Every `from` resolves (input ⊆ upstream output, per field)'
    # -----------------------------------------------------------------------
    # Walk every field entry on both sides of every contract, one level of
    # nesting allowed (e.g. assemble.out.entry.core). Collect:
    #   $refs     — every `from` reference, for the subset check
    #   $inPairs  — (downstream stage, upstream shape) pairs seen on the IN side
    #   $carried  — per upstream shape, the fields any downstream OUT declares
    #               `from` it (that is what "carried through" means, declaratively)
    #   $openOut  — downstream out shapes that are open (a '…' key or an entry
    #               of type 'open'), so residue notes can say unlisted fields flow
    $refs = [System.Collections.Generic.List[object]]::new()
    $inPairs = @{}
    $carried = @{}
    $openOut = @{}
    foreach ($stage in ($contracts.Keys | Sort-Object))
    {
        $c = $contracts[$stage]
        foreach ($side in @('in', 'out'))
        {
            foreach ($shapeName in @($c[$side].Keys | Sort-Object))
            {
                $shape = $c[$side][$shapeName]
                if ($shape -isnot [System.Collections.IDictionary]) { continue }
                $walk = [System.Collections.Generic.List[object]]::new()   # (fieldName, entry, shapePath)
                foreach ($fieldName in @($shape.Keys))
                {
                    $entry = $shape[$fieldName]
                    if ($entry -is [System.Collections.IDictionary] -and -not $entry.ContainsKey('from') -and -not $entry.ContainsKey('type'))
                    {
                        foreach ($nf in @($entry.Keys)) { $walk.Add(@($nf, $entry[$nf], "$shapeName.$fieldName")) }
                    }
                    else { $walk.Add(@($fieldName, $entry, $shapeName)) }
                }
                foreach ($t in $walk)
                {
                    $fName, $fEntry, $fShape = $t
                    if ($fEntry -isnot [System.Collections.IDictionary]) { continue }
                    if ($side -eq 'out' -and ($fName -eq '…' -or ([string]$fEntry['type']) -eq 'open')) { $openOut["$stage.out.$fShape"] = $true }
                    if (-not $fEntry.ContainsKey('from')) { continue }
                    $ref = [string]$fEntry.from
                    $refs.Add(@{ Stage = $stage; Side = $side; Shape = $fShape; Field = $fName; Ref = $ref })
                    if ($side -eq 'in')  { $inPairs["$stage ← $ref"] = @{ Down = $stage; Up = $ref } }
                    if ($side -eq 'out')
                    {
                        if (-not $carried.ContainsKey($ref)) { $carried[$ref] = @{} }
                        $carried[$ref][$fName] = "$stage.out.$fShape"
                    }
                }
            }
        }
    }

    foreach ($r in $refs)
    {
        $why = $null
        $res = Resolve-OutShape $contracts $r.Ref
        if ($res.ContainsKey('Why')) { $why = $res.Why }
        elseif ($res.Stage -eq $r.Stage) { $why = "references its own stage" }
        elseif ($r.Field -notin (Get-ShapeFields $res.Shape)) { $why = "'$($r.Field)' ∉ $($r.Ref) — upstream has: $((Get-ShapeFields $res.Shape) -join ', ')" }
        Assert-True ($null -eq $why) "$($r.Stage).$($r.Side).$($r.Shape).$($r.Field) ← $($r.Ref)" $why
    }
    Assert-True ($refs.Count -gt 0) "at least one \`from\` reference exists across contracts" "got $($refs.Count)"

    # -----------------------------------------------------------------------
    Enter-Section '3. Join residues — upstream out fields no downstream out carries (INFO)'
    # -----------------------------------------------------------------------
    # For each (Y.in ← X.out.S): residue = X.out.S − { f : some Y.out.* declares f from X.out.S }.
    # Those fields exist only in X's retained output; a later consumer reaches
    # them by joining Y.out ⋈ X.out (the orchestrator holds both). Facts, not failures.
    foreach ($key in ($inPairs.Keys | Sort-Object))
    {
        $p = $inPairs[$key]
        $res = Resolve-OutShape $contracts $p.Up
        if ($res.ContainsKey('Why')) { continue }
        $upFields = Get-ShapeFields $res.Shape
        $carriedHere = if ($carried.ContainsKey($p.Up)) { $carried[$p.Up] } else { @{} }
        $carriedByDown = @($carriedHere.Keys | Where-Object { $carriedHere[$_] -like "$($p.Down).out.*" })
        $landing = @($carriedHere.Values | Where-Object { $_ -like "$($p.Down).out.*" } | Sort-Object -Unique)
        $residue = @($upFields | Where-Object { $_ -notin $carriedByDown })
        # A nested landing (X.out.entry.core) inherits openness from its parent (X.out.entry)
        $isOpen = @($landing | Where-Object { $openOut.ContainsKey($_) -or $openOut.ContainsKey(($_ -replace '\.[^.]+$', '')) }).Count -gt 0
        $openNote = if ($isOpen) { "  (landing shape is open — unlisted fields still flow through as elements)" } else { '' }
        if ($residue.Count -eq 0)
        {
            Write-Info "$($p.Up) → $($landing -join ', '): fully carried — no join needed"
        }
        else
        {
            $into = if ($landing.Count -gt 0) { $landing -join ', ' } else { "(nothing in $($p.Down).out declares from $($p.Up))" }
            Write-Info "$($p.Up) − $into = { $($residue -join ', ') }  ← via $($p.Down).out ⋈ $($p.Up.Split('.')[0]).out$openNote"
        }
    }
    Assert-True ($inPairs.Count -gt 0) "at least one in←out pair to compute residues over" "got $($inPairs.Count)"
}
catch
{
    # A terminating error inside the try block would otherwise abort the suite
    # SILENTLY: finally runs, execution resumes, and the summary prints a
    # PASSING count while the remaining asserts never ran. Caught HERE.
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}

# ---------------------------------------------------------------------------
Write-Host "`n═══ contracts.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
