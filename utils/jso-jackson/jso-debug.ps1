# jso-debug.ps1 — Debug & inspection utilities for JSONL data
#
# Dot-source this file to get user-facing inspection / search / compare /
# validate / profile / trace / transform / dedup workflow surface for
# JSONL files. All functions are pipe-friendly and respect module-level
# preview defaults from jso-jackson.ps1.
#
# DEPENDENCIES (must be dot-sourced separately, in any order):
#   jso-jackson.ps1   — primitives (read-side, schema, preview, classes)
#   jso-hash.ps1      — hashing primitives (Find-StringPattern, Get-ContentFingerprint)
#                       used by content-substring search and hash-sidecar diffs.
#
# CONVENTIONS
# -----------
#   -Preview         Switch — apply ConvertTo-JsonPreview before emit.
#                    Defaults read from $script:JsoPreview* (set in jso-jackson).
#   -PreviewMode     Override of preview mode for one call.
#   -MaxFieldChars   Override of preview char budget for one call.
#   -PreviewWindow   Arbitrary window @{ Start; Length }.
#   -Summary         Switch — collapse to one-line tabular row per record.
#   -Path / -At / -Count / -Context   Standardised across functions.
#
# All inspection functions consume Get-JsonlRecord / Read-Jsonl / Get-JsonlHead
# from jso-jackson, so they pick up any index-aware speedups for free.

# -----------------------------------------------------------------------

#region --- Inspection ---

function Show-JsonlStructure
{
    <#
    .SYNOPSIS
        Emit a per-field structure row for a single JSONL record:
        Path, Type, Length.

    .DESCRIPTION
        Walks the record's tree and emits one pscustomobject per node.  Length
        column carries semantic size: char count for strings, item count for
        arrays, $null for scalars and objects.  The natural "probe before
        previewing" tool — answers "what's here" and "how big is it" in one
        call without burning context on the values themselves.

    .PARAMETER Path
        Path to the JSONL file.

    .PARAMETER At
        0-based record index.

    .PARAMETER IndexPath
        Optional override for the .jidx sidecar location.  Defaults to
        `<Path>.jidx`.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int]$At,

        [string]$IndexPath = "$Path.jidx"
    )

    $rec = Get-JsonlRecord -Path $Path -At $At -IndexPath $IndexPath
    $rows = [System.Collections.Generic.List[object]]::new()

    function _Emit
    {
        param([string]$path, [string]$type, [object]$length)
        $rows.Add([pscustomobject]@{ Path = $path; Type = $type; Length = $length })
    }

    function _Walk
    {
        param([object]$obj, [string]$prefix)

        if ($null -eq $obj)
        {
            _Emit -path $prefix -type 'null' -length $null
            return
        }
        if ($obj -is [string])
        {
            _Emit -path $prefix -type 'string' -length $obj.Length
            return
        }
        if ($obj -is [bool])
        {
            _Emit -path $prefix -type 'boolean' -length $null
            return
        }
        if ($obj -is [byte] -or $obj -is [int] -or $obj -is [long] -or `
                $obj -is [double] -or $obj -is [decimal] -or $obj -is [single])
        {
            _Emit -path $prefix -type 'number' -length $null
            return
        }
        if ($obj -is [System.Collections.IDictionary])
        {
            _Emit -path $prefix -type 'object' -length $obj.Count
            foreach ($key in $obj.Keys)
            {
                $childPrefix = if ($prefix) { "$prefix.$key" } else { [string]$key }
                _Walk $obj[$key] $childPrefix
            }
            return
        }
        if ($obj -is [System.Management.Automation.PSCustomObject])
        {
            $props = @($obj.PSObject.Properties)
            _Emit -path $prefix -type 'object' -length $props.Count
            foreach ($p in $props)
            {
                $childPrefix = if ($prefix) { "$prefix.$($p.Name)" } else { $p.Name }
                _Walk $p.Value $childPrefix
            }
            return
        }
        if ($obj -is [System.Collections.IEnumerable])
        {
            $arr = @($obj)
            _Emit -path $prefix -type 'array' -length $arr.Count
            for ($i = 0; $i -lt $arr.Count; $i++)
            {
                _Walk $arr[$i] "$prefix[$i]"
            }
            return
        }
        # Fallback for unknown types
        _Emit -path $prefix -type $obj.GetType().Name -length $null
    }

    _Walk $rec ''
    return $rows.ToArray()
}


function Format-JsonlRecord
{
    <#
    .SYNOPSIS
        Pretty-print a single JSONL record as indented JSON, optionally with
        preview truncation applied.

    .DESCRIPTION
        Reads one record via Get-JsonlRecord and renders it through
        ConvertTo-Json at the minimum lossless depth.  -Preview applies
        ConvertTo-JsonPreview first, truncating long string fields and
        clipping arrays per the module-level preview defaults (overridable
        via -MaxFieldChars / -MaxArrayItems / -PreviewMode / -PreviewWindow).

    .PARAMETER Path
        Path to the JSONL file.

    .PARAMETER At
        0-based record index.

    .PARAMETER Preview
        Switch — apply preview truncation before formatting.

    .PARAMETER MaxFieldChars / MaxArrayItems / PreviewMode / PreviewWindow
        Forwarded to ConvertTo-JsonPreview.  Implies -Preview if any are set.

    .PARAMETER IndexPath
        Optional override for the .jidx sidecar location.

    .EXAMPLE
        Format-JsonlRecord -Path .\thread.jsonl -At 0 -Preview

    .EXAMPLE
        Format-JsonlRecord -Path .\thread.jsonl -At 0 -PreviewMode Sandwich -MaxFieldChars 100
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int]$At,

        [switch]$Preview,

        [int]$MaxFieldChars = $script:JsoPreviewMaxFieldChars,

        [int]$MaxArrayItems = $script:JsoPreviewMaxArrayItems,

        [ValidateSet('Head', 'Tail', 'Middle', 'Sandwich', 'Auto')]
        [string]$PreviewMode = $script:JsoPreviewMode,

        [hashtable]$PreviewWindow,

        [string]$IndexPath = "$Path.jidx"
    )

    $rec = Get-JsonlRecord -Path $Path -At $At -IndexPath $IndexPath

    # Implicit -Preview when any preview-tuning param is explicitly set
    $explicitTune = $PSBoundParameters.ContainsKey('MaxFieldChars') -or
    $PSBoundParameters.ContainsKey('MaxArrayItems') -or
    $PSBoundParameters.ContainsKey('PreviewMode') -or
    $PSBoundParameters.ContainsKey('PreviewWindow')

    if ($Preview -or $explicitTune)
    {
        $rec = $rec | ConvertTo-JsonPreview `
            -MaxFieldChars $MaxFieldChars `
            -MaxArrayItems $MaxArrayItems `
            -PreviewMode $PreviewMode `
            -PreviewWindow $PreviewWindow
    }

    $depth = Get-JsonDepth -InputObject $rec
    if ($depth -lt 1) { $depth = 1 }
    return ($rec | ConvertTo-Json -Depth $depth)
}


function Get-JsonlSample
{
    <#
    .SYNOPSIS
        Random sample of N records from a JSONL file.

    .DESCRIPTION
        Selects N distinct random record indices and reads them via
        Get-JsonlRecord.  Returns records in ascending index order so output
        is reproducible per (file, seed) pair.  When the file has fewer
        records than -Count, returns all records.

    .PARAMETER Path
        Path to the JSONL file.

    .PARAMETER Count
        Sample size.  Default 5.

    .PARAMETER Seed
        Optional seed for the random number generator — fixes the sample for
        reproducible debugging.  When absent, a non-deterministic seed is used.

    .PARAMETER IndexPath
        Optional override for the .jidx sidecar location.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Count = 5,

        [Nullable[int]]$Seed,

        [string]$IndexPath = "$Path.jidx"
    )

    $total = Get-JsonlRecordCount -Path $Path -IndexPath $IndexPath
    if ($total -le 0) { return }
    if ($Count -ge $total)
    {
        Read-Jsonl -Path $Path
        return
    }

    $rng = if ($null -ne $Seed) { [System.Random]::new($Seed) } else { [System.Random]::new() }
    $picks = [System.Collections.Generic.HashSet[int]]::new()
    while ($picks.Count -lt $Count)
    {
        [void]$picks.Add($rng.Next(0, $total))
    }

    $sorted = @($picks) | Sort-Object
    foreach ($i in $sorted)
    {
        Get-JsonlRecord -Path $Path -At $i -IndexPath $IndexPath
    }
}


function Get-JsonlContext
{
    <#
    .SYNOPSIS
        Read the records around a target index — `-At N` plus `-Context K`
        records before and after.

    .DESCRIPTION
        Useful for inspecting boundaries: the record where something broke,
        plus a few before/after for surrounding context.  Each emitted record
        is annotated with a `_index` property so the position is visible
        regardless of how the output is filtered downstream.

    .PARAMETER Path
        Path to the JSONL file.

    .PARAMETER At
        Centre record index (0-based).

    .PARAMETER Context
        Number of records before and after to include.  Default 2.

    .PARAMETER IndexPath
        Optional override for the .jidx sidecar location.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int]$At,

        [int]$Context = 2,

        [string]$IndexPath = "$Path.jidx"
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Get-JsonlContext: file not found: $Path"
    }

    $start = [math]::Max(0, $At - $Context)
    $end = $At + $Context

    # Use index-aware seek when available, streaming-skip otherwise.
    $idx = $null
    if ([System.IO.File]::Exists($IndexPath))
    {
        try
        {
            $candidate = [JsonlIndex]::new($IndexPath)
            if ($candidate.IsValid()) { $idx = $candidate }
        }
        catch { Write-Verbose "Index unreadable, streaming instead: $_" }
    }

    $fs = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )

    $i = 0
    if ($idx -and $start -lt $idx.LineCount)
    {
        $fs.Position = $idx.GetOffset($start)
        $i = $start
    }

    $sr = [System.IO.StreamReader]::new($fs, [System.Text.UTF8Encoding]::new($false))
    try
    {
        while ($null -ne ($line = $sr.ReadLine()) -and $i -le $end)
        {
            if ($i -ge $start)
            {
                $trimmed = $line.Trim()
                if ($trimmed.Length -gt 0)
                {
                    try
                    {
                        $obj = $trimmed | ConvertFrom-Json
                        $obj | Add-Member -NotePropertyName _index -NotePropertyValue $i -PassThru -Force
                    }
                    catch { }
                }
            }
            $i++
        }
    }
    finally { $sr.Dispose() }
}


function Format-JsonlSchema
{
    <#
    .SYNOPSIS
        Render a JsonlSchema as one row per JSON path, sorted lexically by path.

    .DESCRIPTION
        Emits a [pscustomobject] per path with columns Path, Types, Coverage,
        Hits, Records.  Output is pipe-friendly and auto-tabulates under
        PowerShell's default object renderer; pipe to Format-Table -AutoSize
        for terminal column alignment, or to ConvertTo-Csv for export.

        Accepts either an already-probed JsonlSchema (-Schema) or a file path
        (-Path) for one-shot use.  When -Path is supplied the schema probe
        runs internally before formatting.

        Columns:
            Path      Dotted JSON path; arrays denoted by `[]`
            Types     Distinct value kinds observed at this path,
                      `|`-joined (e.g. "string", "string|null", "number")
            Coverage  Percentage of records in which this path appeared
            Hits      Total observations
            Records   Distinct record-index count contributing to Hits

    .PARAMETER Schema
        A JsonlSchema produced by Get-JsonlSchema. Pipeline-bindable.

    .PARAMETER Path
        Path to a JSONL file. When supplied, the probe runs before formatting.

    .PARAMETER StartRecord
        Forwarded to Get-JsonlSchema when -Path is in use. Default 0.

    .PARAMETER EndRecord
        Forwarded to Get-JsonlSchema when -Path is in use. Default -1 (EOF).

    .EXAMPLE
        Format-JsonlSchema -Path .\thread.jsonl | Format-Table -AutoSize

    .EXAMPLE
        $schema = Get-JsonlSchema -Path .\thread.jsonl
        $schema | Format-JsonlSchema | Where-Object { $_.Coverage -lt 100 }
    #>
    [CmdletBinding(DefaultParameterSetName = 'BySchema')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'BySchema')]
        [JsonlSchema]$Schema,

        [Parameter(Mandatory, ParameterSetName = 'ByPath')]
        [string]$Path,

        [Parameter(ParameterSetName = 'ByPath')]
        [int]$StartRecord = 0,

        [Parameter(ParameterSetName = 'ByPath')]
        [int]$EndRecord = -1
    )

    process
    {
        $resolved = if ($PSCmdlet.ParameterSetName -eq 'ByPath')
        {
            Get-JsonlSchema -Path $Path -StartRecord $StartRecord -EndRecord $EndRecord
        }
        else
        {
            $Schema
        }

        if ($null -eq $resolved -or $resolved.Map.Count -eq 0)
        {
            return
        }

        foreach ($key in ($resolved.Map.Keys | Sort-Object))
        {
            $stat = $resolved.Map[$key]
            $types = ($stat.Types | Sort-Object) -join '|'
            [pscustomobject]@{
                Path     = $key
                Types    = $types
                Coverage = $resolved.GetCoverage($key)
                Hits     = $stat.Hits
                Records  = $stat.RecordIds.Count
            }
        }
    }
}

#endregion

#region --- Shared Debug Helpers ---

function _Assert-FindStringAvailable
{
    if (-not (Get-Command Find-StringPattern -CommandType Function -ErrorAction SilentlyContinue))
    {
        throw "Find-StringPattern not available — dot-source jso-hash.ps1 before using substring search."
    }
}


function _Get-ObjectPathValues
{
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$JsonPath
    )

    $segments = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($part in ($JsonPath -split '\.'))
    {
        if ([string]::IsNullOrEmpty($part)) { continue }
        $field = $part
        $iterate = $false
        if ($field -match '^(.*)\[\]$')
        {
            $field = $Matches[1]
            $iterate = $true
        }
        if ($field) { $segments.Add(@{ Op = 'Descend'; Field = $field }) }
        if ($iterate) { $segments.Add(@{ Op = 'IterateArray' }) }
    }

    function _WalkPath
    {
        param([object]$obj, [int]$segIndex)

        if ($segIndex -ge $segments.Count)
        {
            Write-Output $obj
            return
        }
        if ($null -eq $obj) { return }

        $seg = $segments[$segIndex]
        switch ($seg.Op)
        {
            'Descend'
            {
                $field = $seg.Field
                if ($obj -is [System.Management.Automation.PSCustomObject])
                {
                    $prop = $obj.PSObject.Properties[$field]
                    if ($null -eq $prop) { return }
                    _WalkPath -obj $prop.Value -segIndex ($segIndex + 1)
                    return
                }
                if ($obj -is [System.Collections.IDictionary])
                {
                    if (-not $obj.Contains($field)) { return }
                    _WalkPath -obj $obj[$field] -segIndex ($segIndex + 1)
                }
            }
            'IterateArray'
            {
                if ($obj -is [string]) { return }
                if ($obj -is [System.Collections.IEnumerable])
                {
                    foreach ($item in $obj) { _WalkPath -obj $item -segIndex ($segIndex + 1) }
                }
            }
        }
    }

    _WalkPath -obj $InputObject -segIndex 0
}


function _Add-RecordIndex
{
    param([object]$Record, [int]$Index)

    if ($null -eq $Record) { return $null }
    if ($Record -is [System.Management.Automation.PSCustomObject])
    {
        return ($Record | Add-Member -NotePropertyName _index -NotePropertyValue $Index -PassThru -Force)
    }
    return [pscustomobject]@{ _index = $Index; Value = $Record }
}


function _Get-JsonlHashValues
{
    param([Parameter(Mandatory)][string]$IndexPath)

    if (-not [System.IO.File]::Exists($IndexPath))
    {
        throw "Hash sidecar not found: $IndexPath"
    }

    $fs = [System.IO.FileStream]::new(
        $IndexPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $br = [System.IO.BinaryReader]::new($fs)
    try
    {
        if ($fs.Length -lt 12) { throw "Invalid hash sidecar: too small" }
        $magic = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
        if ($magic -ne 'JSHA') { throw "Invalid hash sidecar magic: '$magic'" }
        $version = $br.ReadInt32()
        if ($version -ne 1) { throw "Unsupported hash sidecar version: $version" }
        $count = $br.ReadInt32()
        $values = [long[]]::new($count)
        for ($i = 0; $i -lt $count; $i++) { $values[$i] = $br.ReadInt64() }
        return $values
    }
    finally
    {
        $br.Dispose()
        $fs.Dispose()
    }
}


function _Test-JsonlCondition
{
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [hashtable]$Condition
    )

    $jsonPath = if ($Condition.ContainsKey('JsonPath')) { [string]$Condition.JsonPath } else { [string]$Condition.Path }
    if ([string]::IsNullOrWhiteSpace($jsonPath))
    {
        throw "Condition must include JsonPath or Path."
    }

    $values = @(_Get-ObjectPathValues -InputObject $InputObject -JsonPath $jsonPath)
    if ($Condition.ContainsKey('Exists'))
    {
        $exists = $values.Count -gt 0
        return ($exists -eq [bool]$Condition.Exists)
    }
    if ($Condition.ContainsKey('Equals'))
    {
        foreach ($value in $values) { if ($value -eq $Condition.Equals) { return $true } }
        return $false
    }
    if ($Condition.ContainsKey('NotEquals'))
    {
        foreach ($value in $values) { if ($value -eq $Condition.NotEquals) { return $false } }
        return $true
    }
    if ($Condition.ContainsKey('Matches'))
    {
        foreach ($value in $values) { if ([string]$value -match [string]$Condition.Matches) { return $true } }
        return $false
    }
    if ($Condition.ContainsKey('NotMatches'))
    {
        foreach ($value in $values) { if ([string]$value -match [string]$Condition.NotMatches) { return $false } }
        return $true
    }

    throw "Condition for path '$jsonPath' must include Exists, Equals, NotEquals, Matches, or NotMatches."
}


function _Get-StatsObject
{
    param(
        [Parameter(Mandatory)]
        [long[]]$Values,

        [long]$ByteTotal = 0
    )

    if ($Values.Count -eq 0)
    {
        return [pscustomobject]@{ Count = 0; Min = 0; Max = 0; Mean = 0; Median = 0; P95 = 0; ByteTotal = $ByteTotal }
    }

    $sorted = @($Values | Sort-Object)
    $sum = 0L
    foreach ($v in $Values) { $sum += $v }
    $medianIndex = [int][math]::Floor(($sorted.Count - 1) / 2)
    $p95Index = [int][math]::Ceiling(($sorted.Count - 1) * 0.95)

    return [pscustomobject]@{
        Count     = $Values.Count
        Min       = $sorted[0]
        Max       = $sorted[$sorted.Count - 1]
        Mean      = [math]::Round($sum / [double]$Values.Count, 2)
        Median    = $sorted[$medianIndex]
        P95       = $sorted[$p95Index]
        ByteTotal = $ByteTotal
    }
}

#endregion

#region --- Search ---

function Find-JsonlRecord
{
    [CmdletBinding(DefaultParameterSetName = 'Where')]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Where')]
        [scriptblock]$Where,

        [Parameter(Mandatory, ParameterSetName = 'Containing')]
        [string]$Containing
    )

    if (-not [System.IO.File]::Exists($Path)) { throw "Find-JsonlRecord: file not found: $Path" }
    if ($PSCmdlet.ParameterSetName -eq 'Containing') { _Assert-FindStringAvailable }

    $sr = [System.IO.StreamReader]::new($Path)
    $i = 0
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0) { $i++; continue }

            if ($PSCmdlet.ParameterSetName -eq 'Containing')
            {
                if ((Find-StringPattern -Text $trimmed -Pattern $Containing).Count -gt 0)
                {
                    try { _Add-RecordIndex -Record ($trimmed | ConvertFrom-Json) -Index $i } catch { }
                }
                $i++
                continue
            }

            try { $obj = $trimmed | ConvertFrom-Json } catch { $i++; continue }
            if (@($obj | Where-Object $Where).Count -gt 0)
            {
                _Add-RecordIndex -Record $obj -Index $i
            }
            $i++
        }
    }
    finally { $sr.Dispose() }
}


function Find-JsonlByPath
{
    [CmdletBinding(DefaultParameterSetName = 'Equals')]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$JsonPath,

        [Parameter(Mandatory, ParameterSetName = 'Equals')]
        [AllowNull()]
        [object]$Equals,

        [Parameter(Mandatory, ParameterSetName = 'Matches')]
        [string]$Matches
    )

    if (-not [System.IO.File]::Exists($Path)) { throw "Find-JsonlByPath: file not found: $Path" }

    # Snapshot the pattern before the loop. The -match operator below writes the automatic
    # $Matches variable (capture groups) on the first hit, and that automatic var shadows this
    # parameter of the same name — clobbering it to a hashtable and silently breaking the match
    # for every subsequent record. Reading from a private copy sidesteps the collision.
    $matchPattern = $Matches

    $sr = [System.IO.StreamReader]::new($Path)
    $i = 0
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0) { $i++; continue }
            try { $obj = $trimmed | ConvertFrom-Json } catch { $i++; continue }

            $values = @(_Get-ObjectPathValues -InputObject $obj -JsonPath $JsonPath)
            $hit = $false
            foreach ($value in $values)
            {
                if ($PSCmdlet.ParameterSetName -eq 'Equals')
                {
                    if ($value -eq $Equals) { $hit = $true; break }
                }
                elseif ([string]$value -match $matchPattern)
                {
                    $hit = $true
                    break
                }
            }
            if ($hit) { _Add-RecordIndex -Record $obj -Index $i }
            $i++
        }
    }
    finally { $sr.Dispose() }
}


function Find-JsonlById
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Id
    )

    Find-JsonlRecord -Path $Path -Containing $Id
}


function Find-JsonlByCondition
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable[]]$Condition,

        [ValidateSet('All', 'Any')]
        [string]$Mode = 'All'
    )

    if (-not [System.IO.File]::Exists($Path)) { throw "Find-JsonlByCondition: file not found: $Path" }

    $sr = [System.IO.StreamReader]::new($Path)
    $i = 0
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0) { $i++; continue }
            try { $obj = $trimmed | ConvertFrom-Json } catch { $i++; continue }

            $hits = 0
            foreach ($cond in $Condition)
            {
                if (_Test-JsonlCondition -InputObject $obj -Condition $cond) { $hits++ }
            }

            $matched = if ($Mode -eq 'Any') { $hits -gt 0 } else { $hits -eq $Condition.Count }
            if ($matched) { _Add-RecordIndex -Record $obj -Index $i }
            $i++
        }
    }
    finally { $sr.Dispose() }
}

#endregion

#region --- Compare ---

function Compare-JsonlFiles
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PathA,

        [Parameter(Mandatory)]
        [string]$PathB,

        [switch]$IncludeEqual
    )

    foreach ($path in @($PathA, $PathB))
    {
        if (-not [System.IO.File]::Exists($path)) { throw "Compare-JsonlFiles: file not found: $path" }
    }

    $a = [System.IO.StreamReader]::new($PathA)
    $b = [System.IO.StreamReader]::new($PathB)
    $i = 0
    try
    {
        while ($true)
        {
            $lineA = $a.ReadLine()
            $lineB = $b.ReadLine()
            if ($null -eq $lineA -and $null -eq $lineB) { break }

            $status = if ($null -eq $lineA) { 'OnlyInB' }
            elseif ($null -eq $lineB) { 'OnlyInA' }
            elseif ($lineA -ceq $lineB) { 'Equal' }
            else { 'Changed' }

            if ($IncludeEqual -or $status -ne 'Equal')
            {
                [pscustomobject]@{
                    Index  = $i
                    Status = $status
                    LineA  = $lineA
                    LineB  = $lineB
                }
            }
            $i++
        }
    }
    finally
    {
        $a.Dispose()
        $b.Dispose()
    }
}


function Compare-JsonlSchemas
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PathA,

        [Parameter(Mandatory)]
        [string]$PathB,

        [double]$CoverageTolerance = 0.0
    )

    $schemaA = Get-JsonlSchema -Path $PathA
    $schemaB = Get-JsonlSchema -Path $PathB
    $allPaths = @($schemaA.Map.Keys + $schemaB.Map.Keys | Sort-Object -Unique)

    foreach ($path in $allPaths)
    {
        $inA = $schemaA.Map.ContainsKey($path)
        $inB = $schemaB.Map.ContainsKey($path)
        $typesA = if ($inA) { ($schemaA.Map[$path].Types | Sort-Object) -join '|' } else { '' }
        $typesB = if ($inB) { ($schemaB.Map[$path].Types | Sort-Object) -join '|' } else { '' }
        $coverageA = if ($inA) { $schemaA.GetCoverage($path) } else { 0.0 }
        $coverageB = if ($inB) { $schemaB.GetCoverage($path) } else { 0.0 }

        $status = if (-not $inA) { 'Added' }
        elseif (-not $inB) { 'Removed' }
        elseif ($typesA -ne $typesB) { 'TypeChanged' }
        elseif ([math]::Abs($coverageA - $coverageB) -gt $CoverageTolerance) { 'CoverageChanged' }
        else { 'Equal' }

        if ($status -ne 'Equal')
        {
            [pscustomobject]@{
                Path      = $path
                Status    = $status
                TypesA    = $typesA
                TypesB    = $typesB
                CoverageA = $coverageA
                CoverageB = $coverageB
                HitsA     = if ($inA) { $schemaA.Map[$path].Hits } else { 0 }
                HitsB     = if ($inB) { $schemaB.Map[$path].Hits } else { 0 }
            }
        }
    }
}


function Compare-JsonlByHash
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PathA,

        [Parameter(Mandatory)]
        [string]$PathB,

        [string]$HashPathA = "$PathA.hash",

        [string]$HashPathB = "$PathB.hash",

        [switch]$IncludeEqual,

        [switch]$Rebuild
    )

    foreach ($path in @($PathA, $PathB))
    {
        if (-not [System.IO.File]::Exists($path)) { throw "Compare-JsonlByHash: file not found: $path" }
    }

    if ($Rebuild -or -not (Test-JsonlHashIndex -Path $PathA -IndexPath $HashPathA))
    {
        [void](New-JsonlHashIndex -Path $PathA -IndexPath $HashPathA)
    }
    if ($Rebuild -or -not (Test-JsonlHashIndex -Path $PathB -IndexPath $HashPathB))
    {
        [void](New-JsonlHashIndex -Path $PathB -IndexPath $HashPathB)
    }

    $hashesA = _Get-JsonlHashValues -IndexPath $HashPathA
    $hashesB = _Get-JsonlHashValues -IndexPath $HashPathB
    $max = [math]::Max($hashesA.Count, $hashesB.Count)

    for ($i = 0; $i -lt $max; $i++)
    {
        $hasA = $i -lt $hashesA.Count
        $hasB = $i -lt $hashesB.Count
        $status = if (-not $hasA) { 'OnlyInB' }
        elseif (-not $hasB) { 'OnlyInA' }
        elseif ($hashesA[$i] -eq $hashesB[$i]) { 'Equal' }
        else { 'Changed' }

        if ($IncludeEqual -or $status -ne 'Equal')
        {
            [pscustomobject]@{
                Index  = $i
                Status = $status
                HashA  = if ($hasA) { $hashesA[$i] } else { $null }
                HashB  = if ($hasB) { $hashesB[$i] } else { $null }
            }
        }
    }
}

#endregion

#region --- Validate ---

function Test-Jsonl
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$IncludeValid
    )

    if (-not [System.IO.File]::Exists($Path)) { throw "Test-Jsonl: file not found: $Path" }

    $sr = [System.IO.StreamReader]::new($Path)
    $i = 0
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0)
            {
                [pscustomobject]@{ Index = $i; IsValid = $false; Error = 'Blank line'; Line = $line }
                $i++
                continue
            }
            try
            {
                [void]($trimmed | ConvertFrom-Json)
                if ($IncludeValid) { [pscustomobject]@{ Index = $i; IsValid = $true; Error = $null; Line = $null } }
            }
            catch
            {
                [pscustomobject]@{ Index = $i; IsValid = $false; Error = $_.Exception.Message; Line = $line }
            }
            $i++
        }
    }
    finally { $sr.Dispose() }
}


function Test-JsonlAgainstSchema
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [JsonlSchema]$Schema,

        [double]$CoverageTolerance = 0.0
    )

    $actual = Get-JsonlSchema -Path $Path
    $allPaths = @($Schema.Map.Keys + $actual.Map.Keys | Sort-Object -Unique)

    foreach ($path in $allPaths)
    {
        $expectedHas = $Schema.Map.ContainsKey($path)
        $actualHas = $actual.Map.ContainsKey($path)
        $expectedTypes = if ($expectedHas) { ($Schema.Map[$path].Types | Sort-Object) -join '|' } else { '' }
        $actualTypes = if ($actualHas) { ($actual.Map[$path].Types | Sort-Object) -join '|' } else { '' }
        $expectedCoverage = if ($expectedHas) { $Schema.GetCoverage($path) } else { 0.0 }
        $actualCoverage = if ($actualHas) { $actual.GetCoverage($path) } else { 0.0 }

        $status = if (-not $actualHas) { 'MissingPath' }
        elseif (-not $expectedHas) { 'NewPath' }
        elseif ($expectedTypes -ne $actualTypes) { 'TypeDrift' }
        elseif ([math]::Abs($expectedCoverage - $actualCoverage) -gt $CoverageTolerance) { 'CoverageDrift' }
        else { 'Ok' }

        if ($status -ne 'Ok')
        {
            [pscustomobject]@{
                Path             = $path
                Status           = $status
                ExpectedTypes    = $expectedTypes
                ActualTypes      = $actualTypes
                ExpectedCoverage = $expectedCoverage
                ActualCoverage   = $actualCoverage
            }
        }
    }
}

#endregion

#region --- Profile ---

function Measure-Jsonl
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MaxRecords = 0,

        [ValidateRange(0.000001, 1.0)]
        [double]$SampleRate = 1.0
    )

    if (-not [System.IO.File]::Exists($Path)) { throw "Measure-Jsonl: file not found: $Path" }

    $lengths = [System.Collections.Generic.List[long]]::new()
    $byteTotal = [System.IO.FileInfo]::new($Path).Length
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $rng = if ($SampleRate -lt 1.0) { [System.Random]::new() } else { $null }
    $sr = [System.IO.StreamReader]::new($Path)
    $scanned = 0
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            $scanned++
            if ($MaxRecords -gt 0 -and $scanned -gt $MaxRecords) { break }
            if ($rng -and $rng.NextDouble() -gt $SampleRate) { continue }
            $lengths.Add([long]$encoding.GetByteCount($line))
        }
    }
    finally { $sr.Dispose() }

    $stats = _Get-StatsObject -Values ([long[]]$lengths.ToArray()) -ByteTotal $byteTotal
    return [pscustomobject]@{
        Path            = $Path
        Records         = $stats.Count
        ScannedRecords  = if ($MaxRecords -gt 0 -and $scanned -gt $MaxRecords) { $MaxRecords } else { $scanned }
        SampleRate      = $SampleRate
        SizeBytes       = $byteTotal
        MinLineBytes    = $stats.Min
        MaxLineBytes    = $stats.Max
        MeanLineBytes   = $stats.Mean
        MedianLineBytes = $stats.Median
        P95LineBytes    = $stats.P95
    }
}


function Get-JsonlValueDistribution
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$JsonPath,

        [int]$Top = 100,

        [switch]$All
    )

    $counts = @{}
    foreach ($value in (Select-JsonlPath -Path $Path -JsonPath $JsonPath))
    {
        $key = if ($null -eq $value) { '<null>' } else { [string]$value }
        if (-not $counts.ContainsKey($key)) { $counts[$key] = 0 }
        $counts[$key]++
    }

    $rows = foreach ($key in $counts.Keys)
    {
        [pscustomobject]@{ Value = $key; Count = $counts[$key] }
    }

    $sorted = @($rows | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Value'; Ascending = $true })
    if ($All -or $Top -le 0) { return $sorted }
    return @($sorted | Select-Object -First $Top)
}


function Get-JsonlSizeProfile
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$FatBytes = 0,

        [int]$MaxRecords = 0,

        [ValidateRange(0.000001, 1.0)]
        [double]$SampleRate = 1.0
    )

    if (-not [System.IO.File]::Exists($Path)) { throw "Get-JsonlSizeProfile: file not found: $Path" }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $rng = if ($SampleRate -lt 1.0) { [System.Random]::new() } else { $null }
    $sr = [System.IO.StreamReader]::new($Path)
    $i = 0
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            if ($MaxRecords -gt 0 -and $i -ge $MaxRecords) { break }
            if ($rng -and $rng.NextDouble() -gt $SampleRate) { $i++; continue }
            $bytes = $encoding.GetByteCount($line)
            [pscustomobject]@{
                Index      = $i
                ByteSize   = $bytes
                CharLength = $line.Length
                IsFat      = ($FatBytes -gt 0 -and $bytes -ge $FatBytes)
            }
            $i++
        }
    }
    finally { $sr.Dispose() }
}


function Get-JsonlPathStats
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$JsonPath,

        [int]$MaxValues = 0,

        [ValidateRange(0.000001, 1.0)]
        [double]$SampleRate = 1.0
    )

    $lengths = [System.Collections.Generic.List[long]]::new()
    $byteTotal = 0L
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $rng = if ($SampleRate -lt 1.0) { [System.Random]::new() } else { $null }
    $seen = 0

    foreach ($value in (Select-JsonlPath -Path $Path -JsonPath $JsonPath))
    {
        $seen++
        if ($MaxValues -gt 0 -and $seen -gt $MaxValues) { break }
        if ($rng -and $rng.NextDouble() -gt $SampleRate) { continue }
        if ($null -eq $value) { continue }
        if ($value -is [string])
        {
            $lengths.Add([long]$value.Length)
            $byteTotal += $encoding.GetByteCount($value)
        }
        elseif ($value -is [System.Collections.IEnumerable] -and $value -isnot [string])
        {
            $count = @($value).Count
            $lengths.Add([long]$count)
        }
        else
        {
            $s = [string]$value
            $lengths.Add([long]$s.Length)
            $byteTotal += $encoding.GetByteCount($s)
        }
    }

    _Get-StatsObject -Values ([long[]]$lengths.ToArray()) -ByteTotal $byteTotal
}

#endregion

#region --- Dedup Workflow ---

function Find-JsonlDuplicates
{
    [CmdletBinding(DefaultParameterSetName = 'JsonPath')]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'JsonPath')]
        [string]$JsonPath,

        [Parameter(Mandatory, ParameterSetName = 'ContentHash')]
        [switch]$ContentHash,

        [double]$FalsePositiveRate = 0.01,

        [switch]$Verify
    )

    if (-not [System.IO.File]::Exists($Path)) { throw "Find-JsonlDuplicates: file not found: $Path" }
    if ($PSCmdlet.ParameterSetName -eq 'ContentHash')
    {
        if (-not (Get-Command Get-ExchangeContentHash -CommandType Function -ErrorAction SilentlyContinue))
        {
            throw "Get-ExchangeContentHash not available — dot-source jso-jackson.ps1 and jso-hash.ps1 before using -ContentHash."
        }
    }

    $expected = [math]::Max(1, (Get-JsonlRecordCount -Path $Path))
    $bloom = New-BloomFilter -ExpectedItems $expected -FalsePositiveRate $FalsePositiveRate
    $seen = [System.Collections.Generic.Dictionary[string, int]]::new()
    $valuesByKey = @{}

    $sr = [System.IO.StreamReader]::new($Path)
    $i = 0
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0) { $i++; continue }
            try { $obj = $trimmed | ConvertFrom-Json } catch { $i++; continue }

            $keys = if ($PSCmdlet.ParameterSetName -eq 'ContentHash')
            {
                @([string](Get-ExchangeContentHash -Envelope $obj))
            }
            else
            {
                @(_Get-ObjectPathValues -InputObject $obj -JsonPath $JsonPath | ForEach-Object { if ($null -ne $_) { [string]$_ } })
            }

            foreach ($key in $keys)
            {
                if ([string]::IsNullOrEmpty($key)) { continue }
                $maybeSeen = Test-BloomFilterItem -BloomFilter $bloom -Item $key
                if ($maybeSeen -and $seen.ContainsKey($key))
                {
                    [pscustomobject]@{
                        Key            = $key
                        FirstIndex     = $seen[$key]
                        DuplicateIndex = $i
                        Verified       = if ($Verify) { $valuesByKey[$key] -eq $key } else { $true }
                    }
                }
                else
                {
                    Add-BloomFilterItem -BloomFilter $bloom -Item $key
                    if (-not $seen.ContainsKey($key)) { $seen[$key] = $i }
                    if ($Verify -and -not $valuesByKey.ContainsKey($key)) { $valuesByKey[$key] = $key }
                }
            }

            $i++
        }
    }
    finally { $sr.Dispose() }
}

#endregion
