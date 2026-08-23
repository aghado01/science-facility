#Requires -Version 7.5
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    contracts/container.spec.jsonc — the psr declaration itself, executed.

.DESCRIPTION
    Decision #6: a spec the code does not read has no teeth. rs.core.container
    reads the register, the templates, and the $ref crosswalk — but NOTHING
    reads the `record_pattern` strings. This suite is their reader, and it
    closes the round trip: rows rendered by the module through the spec's
    TEMPLATES are validated against the spec's own PATTERNS. The two sides are
    written independently, so agreement is evidence rather than tautology.

    That round trip is not ceremony. On 2026-08-22 it caught a leader bound of
    {2,3} that rejected the required-only layout (inherited from the
    pre-restructure spec) and an unspecified resolution order that renders
    gidx's pattern as ^[0-9]{digits(EntryCount)}$ and matches nothing.

    Sections:
      1. Declaration — parses, is psr, states the join rule; separator is one
         character and the join is one space (ledger #49).
      2. Crosswalk — every $ref in the register resolves in its target
         contract. Walked here directly, not through the module.
      3. Ordering — col_position and val_rank are unique and total.
      4. Round trip — for every on/off configuration, the leader record_pattern
         matches a row the module rendered; and every column's record_pattern
         matches that column's rendered cell.

.NOTES
    Run from any directory:
        & "$PSScriptRoot\container-spec.tests.ps1"
#>

$v3 = Join-Path $PSScriptRoot '..\reposnapshot-v3'
$specPath = Join-Path $v3 'contracts\container.spec.jsonc'

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

Import-Module (Join-Path $v3 'rs.core.container.psm1') -Force
$utf8 = [System.Text.UTF8Encoding]::new($false)

# --- the test's OWN interpolator: scope ascent, computed forms, regex escape ---
function Resolve-Scoped ([object[]]$Chain, [hashtable]$Columns, [string]$Path, [hashtable]$Widths)
{
    $segs = @($Path -split '\.')
    # ${col.prop} — a column addressed by name takes precedence over ascent.
    if ($Columns.ContainsKey($segs[0]))
    {
        if ($segs.Count -eq 2 -and $segs[1] -eq 'record_width') { return $Widths[$segs[0]] }
        $cur = $Columns[$segs[0]]
        foreach ($k in $segs[1..($segs.Count - 1)]) { $cur = $cur[$k] }
        return $cur
    }
    foreach ($scope in $Chain)
    {
        $cur = $scope; $ok = $true
        foreach ($k in $segs)
        {
            if ($cur -is [System.Collections.IDictionary] -and $cur.Contains($k)) { $cur = $cur[$k] }
            else { $ok = $false; break }
        }
        if ($ok) { return $cur }
    }
    throw "unresolved template reference '`${$Path}'"
}

function ConvertTo-EscapedLiteral ([string]$S)
{
    # conventions: escape EVERY non-word char — [regex]::Escape leaves ] } - alone.
    -join ($S.ToCharArray() | ForEach-Object { if ($_ -match '\w') { $_ } else { '\' + $_ } })
}

function Expand-Pattern ([string]$Pattern, [object[]]$Chain, [hashtable]$Columns, [hashtable]$Widths)
{
    $s = $Pattern
    while ($s -match '\$\{([^}]+)\}')
    {
        $key = $Matches[1]
        $val = [string](Resolve-Scoped $Chain $Columns $key $Widths)
        $s = $s.Replace('${' + $key + '}', (ConvertTo-EscapedLiteral $val))
    }
    return $s
}

function Get-CellTexts ([PSCustomObject]$Layout, [string[]]$Items)
{
    # Walk the layout over Format-Row's flat item list, recovering each
    # column's rendered cell (a block's cell is its bracketed run, rejoined).
    $cells = @{}; $i = 0
    foreach ($col in $Layout.Columns)
    {
        if ($col.Source -eq 'codec.text') { break }
        if ($i -gt 0) { $i++ }                                   # the separator item
        if ($col.Type -eq 'array')
        {
            $len = 2 * @($col.Fields).Count + 1                  # [ v , v , … ]
            $cells[$col.Name] = @($Items[$i..($i + $len - 1)]) -join $Layout.Framing.ItemJoin
            $i += $len
        }
        else
        {
            $cells[$col.Name] = $Items[$i]; $i++
        }
    }
    return $cells
}

function New-Header ([int]$EntryCount, [hashtable]$Elements = @{})
{
    $el = [ordered]@{}
    foreach ($k in $Elements.Keys) { $el[$k] = [pscustomobject]@{ Count = $Elements[$k][0]; Total = $Elements[$k][1] } }
    [pscustomobject]@{ EntryCount = $EntryCount; Elements = [pscustomobject]$el }
}

try
{
    # -----------------------------------------------------------------------
    Enter-Section '1. Declaration'
    # -----------------------------------------------------------------------
    Assert-True (Test-Path -LiteralPath $specPath) 'container.spec.jsonc exists'
    $spec = Get-Content -LiteralPath $specPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($spec.format -eq 'psr') 'format = psr'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$spec.version)) "version is stated ($($spec.version))"
    $S = $spec.shard_container_schema
    Assert-True ($null -ne $S -and $null -ne $S.properties) 'shard_container_schema carries the column register'
    Assert-True ($S.item_join -eq ' ') 'item_join is a single space (ledger #49)' "[$($S.item_join)]"
    Assert-True ($S.column_separator.Length -eq 1) 'column_separator is ONE character — padding is the join, never baked into the separator' $S.column_separator
    Assert-True ($S.record_delimiter -eq "`n") 'record_delimiter is LF alone (ledger #45)'
    Assert-True ($spec.properties.bom -eq $false -and $spec.properties.encoding -eq 'utf-8') 'UTF-8, no BOM'
    foreach ($t in 'header_cell_template', 'header_cell_width_template', 'header_block_template')
    {
        Assert-True ($S[$t] -is [System.Collections.IList]) "$t is an item ARRAY, not a spacing-bearing string"
    }
    Assert-True (@($spec.invariants).Count -ge 2) 'invariants are stated'

    # -----------------------------------------------------------------------
    Enter-Section '2. Crosswalk — every $ref resolves in its target contract'
    # -----------------------------------------------------------------------
    $cache = @{}
    function Test-Ref ([string]$Ref)
    {
        $parts = $Ref -split '#', 2
        if ($parts.Count -ne 2) { return "malformed: $Ref" }
        $file = $parts[0]
        $target = Join-Path (Join-Path $v3 'contracts') $file
        if (-not (Test-Path -LiteralPath $target)) { $target = Join-Path $v3 $file }
        if (-not (Test-Path -LiteralPath $target)) { return "missing file: $file" }
        if (-not $cache.ContainsKey($target)) { $cache[$target] = Get-Content -LiteralPath $target -Raw | ConvertFrom-Json -AsHashtable }
        $node = $cache[$target]
        foreach ($seg in (@(($parts[1].TrimStart('/')) -split '/' | Where-Object { $_ -ne '' })))
        {
            if ($node -is [System.Collections.IDictionary] -and $node.Contains($seg)) { $node = $node[$seg] }
            else { return "dangling: $Ref" }
        }
        return $null
    }

    $refs = @(); $bad = @()
    foreach ($name in $S.properties.Keys)
    {
        $c = $S.properties[$name]
        if ($c.Contains('record_value')) { $refs += , @($name, [string]$c.record_value.'$ref') }
        if ($c.Contains('properties'))
        {
            foreach ($sub in $c.properties.Keys)
            {
                $sd = $c.properties[$sub]
                if ($sd.Contains('val')) { $refs += , @("$name.$sub", [string]$sd.val.'$ref') }
            }
        }
    }
    foreach ($r in $refs) { $err = Test-Ref $r[1]; if ($err) { $bad += "$($r[0]): $err" } }
    Assert-True ($refs.Count -ge 11) "every declared value carries a `$ref ($($refs.Count) found)"
    Assert-True ($bad.Count -eq 0) 'every $ref resolves in its target contract' ($bad -join ' | ')

    # -----------------------------------------------------------------------
    Enter-Section '3. Ordering keys are unique and total'
    # -----------------------------------------------------------------------
    $names = @($S.properties.Keys)
    $pos = @($names | ForEach-Object { [int]$S.properties[$_].col_position })
    Assert-True (@($pos | Sort-Object -Unique).Count -eq $names.Count) 'col_position is unique across columns' ($pos -join ',')
    $cm = $S.properties['content_meta']
    $subs = @($cm.properties.Keys)
    $ranks = @($subs | ForEach-Object { [int]$cm.properties[$_].val_rank })
    Assert-True (@($ranks | Sort-Object -Unique).Count -eq $subs.Count) 'val_rank is unique across content_meta sub-fields' ($ranks -join ',')

    # -----------------------------------------------------------------------
    Enter-Section '4. Round trip — the spec validates rows the module rendered'
    # -----------------------------------------------------------------------
    $entry = [pscustomobject]@{
        RelativePath = 'src/Foo Bar.cs'      # a space in the path: lexing is structural, never a whitespace split
        Content      = "line one`r`nline two`n`ttabbed é"
        ContentMeta  = [pscustomobject]@{ CharCount = 30; WordCount = 5; PunctuationCount = 2; WhitespaceRatio = 0.4037; Entropy = 4.25164; LineStats = [pscustomobject]@{ Mean = 9.5 } }
    }
    $hdr = New-Header 1234 @{ ContentMeta = @(1234, 1234) }

    $configs = @(
        @{ Label = 'all on';           Columns = @('gidx', 'content_meta') }
        @{ Label = 'required only';    Columns = @() }
        @{ Label = 'gidx off';         Columns = @('content_meta') }
        @{ Label = 'content_meta off'; Columns = @('gidx') }
    )

    foreach ($cfg in $configs)
    {
        $L = Resolve-Layout -Header $hdr -Columns $cfg.Columns -WarningAction SilentlyContinue
        $widths = @{}
        foreach ($col in $L.Columns) { if ($null -ne $col.Width) { $widths[$col.Name] = $col.Width } }
        $colMap = @{}; foreach ($k in $S.properties.Keys) { $colMap[$k] = $S.properties[$k] }

        $gidx = if ($cfg.Columns -contains 'gidx') { 42 } else { $null }
        $row = $utf8.GetString((Build-Row -Layout $L -Entry $entry -Cursor 0 -GlobalIdx $gidx).Bytes)

        $leader = Expand-Pattern ([string]$S.record_pattern) @($S) $colMap $widths
        Assert-True ([regex]::IsMatch($row, $leader)) "leader record_pattern matches a rendered row — $($cfg.Label)" $row.Split("`n")[0]

        $f = Format-Row -Layout $L -Entry $entry -GlobalIdx $gidx
        $cells = Get-CellTexts $L $f.Items
        foreach ($col in $L.Columns)
        {
            if ($col.Source -eq 'codec.text') { continue }
            $decl = $S.properties[$col.Name]
            if (-not $decl.Contains('record_pattern') -or $null -eq $decl.record_pattern) { continue }
            $p = Expand-Pattern ([string]$decl.record_pattern) @($decl, $S) $colMap $widths
            Assert-True ([regex]::IsMatch($cells[$col.Name], $p)) "  $($col.Name) record_pattern matches its rendered cell — $($cfg.Label)" "cell='$($cells[$col.Name])' pattern=$p"
        }
    }

    # the byte identity the declaration states, checked from the declaration's side
    $L = Resolve-Layout -Header $hdr -Columns gidx, content_meta
    $f = Format-Row -Layout $L -Entry $entry -GlobalIdx 42
    $sum = 0; foreach ($i in $f.Items) { $sum += $utf8.GetByteCount($i) }
    $sum += $utf8.GetByteCount([string]$S.column_separator) + $f.ContentBytes
    $n = $f.Items.Count + 2
    $identity = $sum + ($n - 1) * $utf8.GetByteCount([string]$S.item_join) + $utf8.GetByteCount([string]$S.record_delimiter)
    Assert-True ((Measure-Row -Layout $L -Entry $entry) -eq $identity) 'invariant: row bytes = Σ item bytes + (item count − 1) + record_delimiter'
    Assert-True ($L.HeaderBytes -eq ($utf8.GetByteCount($L.HeaderRowText) + $utf8.GetByteCount([string]$S.record_delimiter))) 'invariant: one header per run, HeaderBytes = utf8(text) + record_delimiter'
}
catch
{
    Assert-True $false "SUITE ABORTED: $($_.Exception.Message)" $_.ScriptStackTrace
}

Write-Host "`n═══ container-spec.tests: $script:Passed passed, $script:Failed failed ═══" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
