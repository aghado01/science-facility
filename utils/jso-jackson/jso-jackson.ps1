# jso-jackson.ps1 — Schema-agnostic JSONL engine
#
# Dot-source this file to get the base JSONL primitives:
#
#   . "D:\aghado01\science-facility\utils\jso-jackson\jso-jackson.ps1"
#
# CLASSES
# ------
#   JsonlIndex        Binary seek index (.jidx) — build, load, seek by line number.
#   JsonlSchemaStat   Per-path accumulator for schema recovery.
#   JsonlSchema       Full schema probe result — path/type/coverage map.
#   JsonlTraversal    Fluent filter/extract engine over a snapshot. Operates entirely
#                     in System.Text.Json land. No PSCustomObject — subclass owns that.
#   JsonlFile         Mount point factory. Binds a snapshot + index for traversal.
#
# FUNCTIONS
# ---------
#   New-JsonlSnapshot   Phase 1 ingest: copy source JSONL to working dir with LF
#                       normalization, tail validation, and .jidx build. Returns
#                       metadata object with SnapshotPath, IndexPath, LineCount.
#
#   New-JobWorkingDir   Mint a timestamped working directory under a parameterized root.
#                       Returns the created directory path.
#
#   ConvertTo-CanonicalJson   Serialize any PSCustomObject/hashtable to compact or
#                             pretty JSON using programmatically computed depth.
#   Merge-JsonObjects         Right-wins shallow merge of two PSCustomObjects.
#   Get-JsonDepth             Recursively compute the minimum lossless serialization
#                             depth of a PSCustomObject or hashtable.
#   New-BloomFilter           Create a probabilistic set membership filter sized for
#                             expected item count and false positive rate.
#   Add-BloomFilterItem       Register an item in the bloom filter.
#   Test-BloomFilterItem      Test set membership (no false negatives; check HashSet
#                             on true to eliminate false positives).
#
# DESIGN CONTRACT
# ---------------
#   - This file is NOT a user-facing entry point. It is consumed by domain-specific
#     subclass files (e.g. claude-jso-jackson.ps1) that add schema knowledge and
#     domain output.
#
#   READ PATH (performance-sensitive):
#   - All internal record handling uses [System.Text.Json.JsonElement].
#   - No PSCustomObject is ever created in the read/filter/traverse pipeline.
#   - The only PS type surface is [string], [long], [bool], [double], and the
#     classes defined here.
#
#   WRITE PATH (serialization boundary):
#   - PSCustomObject IS used as the write-side serialization boundary.
#   - Write-side helpers (ConvertTo-CanonicalJson, Merge-JsonObjects) produce JSON
#     via ConvertTo-Json — no manual string construction, no hand-rolled escaping.
#   - Depth is always computed programmatically via Get-JsonDepth to guarantee
#     lossless round-trips without magic numbers.
#   - Domain subclasses call these helpers freely.
#
#   DEDUPLICATION:
#   - New-BloomFilter / Add-BloomFilterItem / Test-BloomFilterItem implement a
#     probabilistic pre-filter (no false negatives). Always pair with an exact
#     HashSet check to eliminate false positives (hybrid pattern).
#
#   BINARY INDEX:
#   - .jidx format: magic "JSOI" (4B) + version int32 + lineCount int32
#     + int64[offset] * lineCount. Built by JsonlIndex.Build() via byte-scanning
#     (no string allocation). Read via JsonlIndex.LoadIndex().
#
# DEPENDENCY
# ----------
#   None. Self-contained. Requires PowerShell 7+ (System.Text.Json is inbox).
# -----------------------------------------------------------------------

#region --- JsonlIndex ---

class JsonlIndex
{
    [string] $IndexPath
    [int]    $LineCount
    hidden [long[]] $Offsets

    JsonlIndex([string]$indexPath)
    {
        $this.IndexPath = $indexPath
        $this.LoadIndex()
    }

    hidden [void] LoadIndex()
    {
        $fs = [System.IO.FileStream]::new(
            $this.IndexPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $br = [System.IO.BinaryReader]::new($fs)
        try
        {
            $magic = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
            if ($magic -ne 'JSOI') { throw "Invalid .jidx magic: '$magic'" }
            $ver = $br.ReadInt32()
            if ($ver -ne 1) { throw "Unsupported .jidx version: $ver" }
            $this.LineCount = $br.ReadInt32()
            $this.Offsets = [long[]]::new($this.LineCount)
            for ($i = 0; $i -lt $this.LineCount; $i++)
            {
                $this.Offsets[$i] = $br.ReadInt64()
            }
        }
        finally
        {
            $br.Dispose()
            $fs.Dispose()
        }
    }

    [bool] IsValid()
    {
        if (-not [System.IO.File]::Exists($this.IndexPath)) { return $false }
        try
        {
            $fs = [System.IO.FileStream]::new(
                $this.IndexPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read
            )
            $br = [System.IO.BinaryReader]::new($fs)
            try
            {
                if ($fs.Length -lt 12) { return $false }
                $magic = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
                return ($magic -eq 'JSOI')
            }
            finally
            {
                $br.Dispose()
                $fs.Dispose()
            }
        }
        catch { return $false }
    }

    [long] GetOffset([int]$lineIndex)
    {
        if ($lineIndex -lt 0 -or $lineIndex -ge $this.LineCount)
        {
            throw "Line index $lineIndex out of range [0, $($this.LineCount - 1)]"
        }
        return $this.Offsets[$lineIndex]
    }

    static [JsonlIndex] Build([string]$snapshotPath, [string]$indexPath)
    {
        $byteOffsets = [System.Collections.Generic.List[long]]::new()
        $buildFs = [System.IO.FileStream]::new(
            $snapshotPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try
        {
            [long]$pos = 0
            [long]$fileLen = $buildFs.Length
            $buf = [byte[]]::new(65536)
            if ($fileLen -gt 0)
            {
                $byteOffsets.Add(0L)
            }

            while (($bytesRead = $buildFs.Read($buf, 0, $buf.Length)) -gt 0)
            {
                for ($i = 0; $i -lt $bytesRead; $i++)
                {
                    if ($buf[$i] -eq 0x0A)
                    {
                        $nextOffset = $pos + $i + 1
                        if ($nextOffset -lt $fileLen)
                        {
                            $byteOffsets.Add($nextOffset)
                        }
                    }
                }
                $pos += $bytesRead
            }
        }
        finally { $buildFs.Dispose() }

        # Write .jidx
        $idxFs = [System.IO.FileStream]::new(
            $indexPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write
        )
        $bw = [System.IO.BinaryWriter]::new($idxFs)
        try
        {
            $bw.Write([System.Text.Encoding]::ASCII.GetBytes('JSOI'))
            $bw.Write([int]1)
            $bw.Write([int]$byteOffsets.Count)
            foreach ($o in $byteOffsets) { $bw.Write([long]$o) }
        }
        finally
        {
            $bw.Dispose()
            $idxFs.Dispose()
        }

        return [JsonlIndex]::new($indexPath)
    }
}

#endregion

#region --- JsonlSchema ---

class JsonlSchemaStat
{
    [int]    $Hits
    [System.Collections.Generic.HashSet[int]]    $RecordIds
    [System.Collections.Generic.HashSet[string]] $Types

    JsonlSchemaStat()
    {
        $this.Hits = 0
        $this.RecordIds = [System.Collections.Generic.HashSet[int]]::new()
        $this.Types = [System.Collections.Generic.HashSet[string]]::new()
    }
}

class JsonlSchema
{
    [System.Collections.Generic.Dictionary[string, JsonlSchemaStat]] $Map
    [int] $TotalRecords

    JsonlSchema()
    {
        $this.Map = [System.Collections.Generic.Dictionary[string, JsonlSchemaStat]]::new()
        $this.TotalRecords = 0
    }

    [void] AddObservation([string]$path, [string]$typeName, [int]$recordIndex)
    {
        if (-not $this.Map.ContainsKey($path))
        {
            $this.Map[$path] = [JsonlSchemaStat]::new()
        }
        $stat = $this.Map[$path]
        $stat.Hits++
        [void]$stat.RecordIds.Add($recordIndex)
        [void]$stat.Types.Add($typeName)
    }

    [bool] ContainsField([string]$path)
    {
        return $this.Map.ContainsKey($path)
    }

    [string[]] GetTypes([string]$path)
    {
        if ($this.Map.ContainsKey($path))
        {
            return [string[]]$this.Map[$path].Types
        }
        return @()
    }

    [double] GetCoverage([string]$path)
    {
        if ($this.TotalRecords -eq 0) { return 0.0 }
        if ($this.Map.ContainsKey($path))
        {
            return [math]::Round($this.Map[$path].RecordIds.Count / $this.TotalRecords * 100, 1)
        }
        return 0.0
    }

    # Walk a JsonElement recursively, accumulating path/type observations.
    static [void] WalkElement(
        [System.Text.Json.JsonElement]$element,
        [string]$prefix,
        [JsonlSchema]$schema,
        [int]$recordIndex
    )
    {
        switch ($element.ValueKind)
        {
            ([System.Text.Json.JsonValueKind]::Object)
            {
                foreach ($prop in $element.EnumerateObject())
                {
                    $path = if ($prefix) { "$prefix.$($prop.Name)" } else { $prop.Name }
                    [JsonlSchema]::WalkElement($prop.Value, $path, $schema, $recordIndex)
                }
            }
            ([System.Text.Json.JsonValueKind]::Array)
            {
                $arrayPath = "${prefix}[]"
                foreach ($item in $element.EnumerateArray())
                {
                    [JsonlSchema]::WalkElement($item, $arrayPath, $schema, $recordIndex)
                }
            }
            ([System.Text.Json.JsonValueKind]::String) { $schema.AddObservation($prefix, 'string', $recordIndex) }
            ([System.Text.Json.JsonValueKind]::Number) { $schema.AddObservation($prefix, 'number', $recordIndex) }
            ([System.Text.Json.JsonValueKind]::True) { $schema.AddObservation($prefix, 'boolean', $recordIndex) }
            ([System.Text.Json.JsonValueKind]::False) { $schema.AddObservation($prefix, 'boolean', $recordIndex) }
            ([System.Text.Json.JsonValueKind]::Null) { $schema.AddObservation($prefix, 'null', $recordIndex) }
        }
    }
}

#endregion

#region --- JsonlTraversal ---

class JsonlTraversal
{
    hidden [string]    $SnapshotPath
    hidden [JsonlIndex] $Index          # $null if no index available

    # Builder state — specs stored, executed on Stream()
    hidden [int]    $StartRecord = 0
    hidden [int]    $EndRecord = -1      # -1 = no upper bound
    hidden [int]    $SkipCount = 0
    hidden [int]    $TakeCount = -1      # -1 = no limit
    hidden [bool]   $SchemaMode = $false

    hidden [System.Collections.Generic.List[string]]   $ExcludeTruePaths
    hidden [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]] $IncludeValueFilters
    hidden [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]] $ExcludeValueFilters
    hidden [System.Collections.Generic.List[scriptblock]] $Predicates
    hidden [System.Collections.Generic.List[object]]   $SortSpec

    JsonlTraversal([string]$snapshotPath, [JsonlIndex]$index)
    {
        $this.SnapshotPath = $snapshotPath
        $this.Index = $index
        $this.ExcludeTruePaths = [System.Collections.Generic.List[string]]::new()
        $this.IncludeValueFilters = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new()
        $this.ExcludeValueFilters = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new()
        $this.Predicates = [System.Collections.Generic.List[scriptblock]]::new()
        $this.SortSpec = [System.Collections.Generic.List[object]]::new()
    }

    #region Fluent builders — store specs, return $this

    [JsonlTraversal] LineRange([int]$start, [int]$end)
    {
        $this.StartRecord = $start
        $this.EndRecord = $end
        return $this
    }

    [JsonlTraversal] Skip([int]$count)
    {
        $this.SkipCount = $count
        return $this
    }

    [JsonlTraversal] Take([int]$count)
    {
        $this.TakeCount = $count
        return $this
    }

    [JsonlTraversal] Where([scriptblock]$predicate)
    {
        $this.Predicates.Add($predicate)
        return $this
    }

    [JsonlTraversal] ExcludeWhenTrue([string[]]$paths)
    {
        foreach ($p in $paths) { $this.ExcludeTruePaths.Add($p) }
        return $this
    }

    [JsonlTraversal] IncludePathValues([string]$path, [string[]]$values)
    {
        if (-not $this.IncludeValueFilters.ContainsKey($path))
        {
            $this.IncludeValueFilters[$path] = [System.Collections.Generic.List[string]]::new()
        }
        foreach ($v in $values) { $this.IncludeValueFilters[$path].Add($v) }
        return $this
    }

    [JsonlTraversal] ExcludePathValues([string]$path, [string[]]$values)
    {
        if (-not $this.ExcludeValueFilters.ContainsKey($path))
        {
            $this.ExcludeValueFilters[$path] = [System.Collections.Generic.List[string]]::new()
        }
        foreach ($v in $values) { $this.ExcludeValueFilters[$path].Add($v) }
        return $this
    }

    # SortBy accepts an array of specs: strings (shorthand ASC) or hashtables
    # with Field and Order keys. Applied after filtering in Stream().
    # Example: .SortBy(@('timestamp'))
    # Example: .SortBy(@(@{ Field = 'timestamp'; Order = 'ASC' }, @{ Field = 'type'; Order = 'DESC' }))
    [JsonlTraversal] SortBy([object[]]$sortSpec)
    {
        foreach ($entry in $sortSpec) { $this.SortSpec.Add($entry) }
        return $this
    }

    [JsonlTraversal] SchemaRecover()
    {
        $this.SchemaMode = $true
        return $this
    }

    #endregion

    #region Core: Stream() — returns filtered, sorted JsonElement array

    # The primary internal surface consumed by subclasses.
    # Returns JsonElement[] after applying all filter/sort/skip/take specs.
    hidden [System.Text.Json.JsonElement[]] Stream()
    {
        if ($this.SchemaMode)
        {
            throw "Stream() not available in SchemaMode. Use RunSchemaProbe() instead."
        }

        $collected = [System.Collections.Generic.List[System.Text.Json.JsonElement]]::new()

        $fs = [System.IO.FileStream]::new(
            $this.SnapshotPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )

        # Seek via index if LineRange start is set and index is available
        if ($this.StartRecord -gt 0 -and $null -ne $this.Index -and $this.Index.IsValid())
        {
            $fs.Position = $this.Index.GetOffset($this.StartRecord)
        }

        $encoding = [System.Text.UTF8Encoding]::new($false)
        $sr = [System.IO.StreamReader]::new($fs, $encoding)

        [int]$lineIndex = 0
        [int]$accepted = 0
        [int]$skipped = 0

        # If we seeked, lineIndex starts at StartRecord
        if ($this.StartRecord -gt 0 -and $null -ne $this.Index -and $this.Index.IsValid())
        {
            $lineIndex = $this.StartRecord
        }

        try
        {
            while ($null -ne ($line = $sr.ReadLine()))
            {
                # LineRange: skip lines before StartRecord (streaming fallback if no index)
                if ($lineIndex -lt $this.StartRecord)
                {
                    $lineIndex++
                    continue
                }
                # LineRange: stop after EndRecord
                if ($this.EndRecord -ge 0 -and $lineIndex -gt $this.EndRecord)
                {
                    break
                }
                $lineIndex++

                $trimmed = $line.Trim()
                if ($trimmed.Length -eq 0) { continue }

                # Parse
                [System.Text.Json.JsonElement]$element = [System.Text.Json.JsonElement]::new()
                try
                {
                    $element = [System.Text.Json.JsonSerializer]::Deserialize($trimmed, [System.Text.Json.JsonElement])
                }
                catch { continue }  # skip malformed lines

                # Apply filters
                if (-not $this.TestFilters($element)) { continue }

                # Skip
                if ($skipped -lt $this.SkipCount)
                {
                    $skipped++
                    continue
                }

                $collected.Add($element)

                # Take
                $accepted++
                if ($this.TakeCount -ge 0 -and $accepted -ge $this.TakeCount)
                {
                    break
                }
            }
        }
        finally
        {
            $sr.Dispose()
            $fs.Dispose()
        }

        # Sort if spec is present
        if ($this.SortSpec.Count -gt 0)
        {
            return [System.Text.Json.JsonElement[]]($this.ApplySort($collected))
        }

        return $collected.ToArray()
    }

    # Schema probe: single-pass path/type/coverage accumulation.
    hidden [JsonlSchema] RunSchemaProbe()
    {
        $schema = [JsonlSchema]::new()

        $encoding = [System.Text.UTF8Encoding]::new($false)
        $fs = [System.IO.FileStream]::new(
            $this.SnapshotPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $sr = [System.IO.StreamReader]::new($fs, $encoding)

        [int]$lineIndex = 0
        [int]$recordIndex = 0

        try
        {
            while ($null -ne ($line = $sr.ReadLine()))
            {
                if ($lineIndex -lt $this.StartRecord) { $lineIndex++; continue }
                if ($this.EndRecord -ge 0 -and $lineIndex -gt $this.EndRecord) { break }
                $lineIndex++

                $trimmed = $line.Trim()
                if ($trimmed.Length -eq 0) { continue }

                try
                {
                    $element = [System.Text.Json.JsonSerializer]::Deserialize($trimmed, [System.Text.Json.JsonElement])
                }
                catch { continue }

                if (-not $this.TestFilters($element)) { continue }

                [JsonlSchema]::WalkElement($element, '', $schema, $recordIndex)
                $recordIndex++
            }
        }
        finally
        {
            $sr.Dispose()
            $fs.Dispose()
        }

        $schema.TotalRecords = $recordIndex
        return $schema
    }

    #endregion

    #region Filter evaluation

    hidden [bool] TestFilters([System.Text.Json.JsonElement]$element)
    {
        # ExcludeWhenTrue — if any named path has a truthy value, reject
        foreach ($path in $this.ExcludeTruePaths)
        {
            $val = [JsonlTraversal]::GetElementValue($element, $path)
            if ($null -ne $val -and $val -is [bool] -and $val -eq $true)
            {
                return $false
            }
            # Also treat string "true" and non-zero numbers as truthy
            if ($null -ne $val -and $val -is [string] -and $val -eq 'true')
            {
                return $false
            }
        }

        # IncludePathValues — whitelist: field value must be in list (if any filter set for that path)
        foreach ($kvp in $this.IncludeValueFilters.GetEnumerator())
        {
            $val = [JsonlTraversal]::GetElementValue($element, $kvp.Key)
            $strVal = if ($null -eq $val) { '' } else { [string]$val }
            if ($strVal -notin $kvp.Value)
            {
                return $false
            }
        }

        # ExcludePathValues — blacklist: reject if field value is in list
        foreach ($kvp in $this.ExcludeValueFilters.GetEnumerator())
        {
            $val = [JsonlTraversal]::GetElementValue($element, $kvp.Key)
            $strVal = if ($null -eq $val) { '' } else { [string]$val }
            if ($strVal -in $kvp.Value)
            {
                return $false
            }
        }

        # Custom predicates — all must pass
        foreach ($pred in $this.Predicates)
        {
            $result = & $pred $element
            if (-not $result) { return $false }
        }

        return $true
    }

    #endregion

    #region Sort

    hidden [System.Text.Json.JsonElement[]] ApplySort(
        [System.Collections.Generic.List[System.Text.Json.JsonElement]]$elements
    )
    {
        # Normalize sort spec to array of @{ Field; Order }
        $specs = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($entry in $this.SortSpec)
        {
            if ($entry -is [string])
            {
                $specs.Add(@{ Field = $entry; Order = 'ASC' })
            }
            elseif ($entry -is [hashtable])
            {
                $specs.Add(@{
                        Field = [string]$entry.Field
                        Order = if ($entry.Order) { [string]$entry.Order } else { 'ASC' }
                    })
            }
        }

        $count = $elements.Count
        if ($count -le 1) { return $elements.ToArray() }

        # Pre-extract sort key values for each element x spec
        $keyStore = [System.Collections.Generic.List[object]]::new()
        foreach ($spec in $specs)
        {
            $keys = [object[]]::new($count)
            for ($i = 0; $i -lt $count; $i++)
            {
                $keys[$i] = [JsonlTraversal]::GetElementValue($elements[$i], $spec.Field)
            }
            $keyStore.Add(@{ Keys = $keys; Desc = ($spec.Order -eq 'DESC') })
        }

        # Build sortable wrapper array: [index, element] pairs sorted via LINQ-style comparison
        $indices = [int[]]::new($count)
        for ($i = 0; $i -lt $count; $i++) { $indices[$i] = $i }

        # Simple insertion sort (stable, correct for class-method context where closures are tricky)
        for ($outer = 1; $outer -lt $count; $outer++)
        {
            $key = $indices[$outer]
            $inner = $outer - 1
            while ($inner -ge 0)
            {
                $cmpResult = 0
                foreach ($ka in $keyStore)
                {
                    $va = $ka.Keys[$indices[$inner]]
                    $vb = $ka.Keys[$key]
                    if ($null -eq $va -and $null -eq $vb) { $cmpResult = 0 }
                    elseif ($null -eq $va) { $cmpResult = -1 }
                    elseif ($null -eq $vb) { $cmpResult = 1 }
                    elseif ($va -is [System.IComparable]) { $cmpResult = $va.CompareTo($vb) }
                    else { $cmpResult = [string]::Compare([string]$va, [string]$vb, [System.StringComparison]::Ordinal) }
                    if ($ka.Desc) { $cmpResult = - $cmpResult }
                    if ($cmpResult -ne 0) { break }
                }
                if ($cmpResult -le 0) { break }
                $indices[$inner + 1] = $indices[$inner]
                $inner--
            }
            $indices[$inner + 1] = $key
        }

        $sorted = [System.Text.Json.JsonElement[]]::new($count)
        for ($i = 0; $i -lt $count; $i++)
        {
            $sorted[$i] = $elements[$indices[$i]]
        }
        return $sorted
    }

    #endregion

    #region Static helpers — JsonElement dot-path navigation

    # Navigate a dot-separated path on a JsonElement, returning the scalar value
    # at the leaf. Returns $null if any segment is missing.
    # Does NOT handle [] array expansion — that's for schema probe only.
    static [object] GetElementValue(
        [System.Text.Json.JsonElement]$element,
        [string]$path
    )
    {
        $segments = $path.Split('.')
        $current = $element

        foreach ($seg in $segments)
        {
            if ($current.ValueKind -eq [System.Text.Json.JsonValueKind]::Null -or
                $current.ValueKind -eq [System.Text.Json.JsonValueKind]::Undefined)
            {
                return $null
            }
            if ($current.ValueKind -ne [System.Text.Json.JsonValueKind]::Object)
            {
                return $null
            }
            try
            {
                $current = $current.GetProperty($seg)
            }
            catch
            {
                return $null
            }
        }

        return [JsonlTraversal]::UnboxElement($current)
    }

    # Convert a JsonElement leaf to a PS-friendly scalar.
    static hidden [object] UnboxElement([System.Text.Json.JsonElement]$el)
    {
        switch ($el.ValueKind)
        {
            ([System.Text.Json.JsonValueKind]::String) { return $el.GetString() }
            ([System.Text.Json.JsonValueKind]::True) { return $true }
            ([System.Text.Json.JsonValueKind]::False) { return $false }
            ([System.Text.Json.JsonValueKind]::Null) { return $null }
            ([System.Text.Json.JsonValueKind]::Undefined) { return $null }
            ([System.Text.Json.JsonValueKind]::Number)
            {
                [long]$longVal = 0
                if ($el.TryGetInt64([ref]$longVal)) { return $longVal }
                return $el.GetDouble()
            }
        }
        # Object or Array — return raw element for caller to handle
        return $el
    }

    # Get the raw JsonElement at a dot-path without unboxing.
    # Useful when caller needs to inspect ValueKind or enumerate children.
    static [System.Text.Json.JsonElement] GetElementRaw(
        [System.Text.Json.JsonElement]$element,
        [string]$path
    )
    {
        $segments = $path.Split('.')
        $current = $element

        foreach ($seg in $segments)
        {
            if ($current.ValueKind -ne [System.Text.Json.JsonValueKind]::Object)
            {
                return [System.Text.Json.JsonElement]::new()
            }
            try
            {
                $current = $current.GetProperty($seg)
            }
            catch
            {
                return [System.Text.Json.JsonElement]::new()
            }
        }

        return $current
    }

    #endregion
}

#endregion

#region --- JsonlFile ---

class JsonlFile
{
    [string]    $SnapshotPath
    [string]    $IndexPath
    [JsonlIndex] $Index

    JsonlFile([string]$snapshotPath, [string]$indexPath)
    {
        $this.SnapshotPath = $snapshotPath
        $this.IndexPath = $indexPath
        if ($indexPath -and [System.IO.File]::Exists($indexPath))
        {
            $this.Index = [JsonlIndex]::new($indexPath)
        }
    }

    static [JsonlFile] MountSnapshot([string]$snapshotPath, [string]$indexPath)
    {
        return [JsonlFile]::new($snapshotPath, $indexPath)
    }

    [JsonlTraversal] Traverse()
    {
        return [JsonlTraversal]::new($this.SnapshotPath, $this.Index)
    }
}

#endregion

#region --- Schema Helpers ---

# =============================================================================
# SCHEMA HELPERS — public surface for the JsonlSchema probe.
# Wraps the JsonlTraversal.SchemaRecover() / RunSchemaProbe() pattern as a
# one-shot function and provides a tabular pretty-printer.
# =============================================================================

function Get-JsonlSchema
{
    <#
    .SYNOPSIS
        Run a single-pass schema probe over a JSONL file.

    .DESCRIPTION
        Walks every record in the file and accumulates per-path observations
        (types seen, hit count, contributing record indices). Returns a
        JsonlSchema object whose Map is keyed by dotted JSON path; arrays in
        the path are denoted by `[]` (e.g. `records[]._type`).

        Optional record-range slicing via StartRecord / EndRecord (0-based,
        inclusive bounds; -1 = no upper bound on EndRecord).

        For tabular output pipe through Format-JsonlSchema, or pass -Path
        directly to Format-JsonlSchema and skip this call.

    .PARAMETER Path
        Path to a JSONL file.

    .PARAMETER StartRecord
        First record (0-based) to include. Default 0.

    .PARAMETER EndRecord
        Last record (0-based, inclusive) to include. -1 (default) = read to EOF.

    .EXAMPLE
        $schema = Get-JsonlSchema -Path .\thread.jsonl
        $schema.GetCoverage('records[].text')
        # → 100.0

    .EXAMPLE
        Get-JsonlSchema -Path .\thread.jsonl | Format-JsonlSchema | Format-Table -AutoSize
    #>
    [CmdletBinding()]
    [OutputType([JsonlSchema])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$StartRecord = 0,

        [int]$EndRecord = -1
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Get-JsonlSchema: file not found: $Path"
    }

    $tr = [JsonlTraversal]::new($Path, $null)
    if ($StartRecord -gt 0 -or $EndRecord -ge 0)
    {
        [void]$tr.LineRange($StartRecord, $EndRecord)
    }
    [void]$tr.SchemaRecover()
    return $tr.RunSchemaProbe()
}

# Format-JsonlSchema lives in jso-debug.ps1 (user-facing formatter; see
# jso-debug for the moved function).

#endregion

#region --- Preview Primitive ---

# =============================================================================
# PREVIEW PRIMITIVE — token-pinching truncator for any object tree.
# Used by jso-debug formatters (Format-JsonlRecord -Preview, etc.) and
# directly callable for ad-hoc clipping of objects before display.
#
# Module-level defaults are read from script-scoped variables; functions can
# override by passing parameters explicitly. Rebind `$script:JsoPreview*`
# from a consumer session to change defaults globally.
# =============================================================================

if ($null -eq $script:JsoPreviewMaxFieldChars) { $script:JsoPreviewMaxFieldChars = 200 }
if ($null -eq $script:JsoPreviewMaxArrayItems) { $script:JsoPreviewMaxArrayItems = 5 }
if ($null -eq $script:JsoPreviewMode) { $script:JsoPreviewMode = 'Auto' }


function ConvertTo-JsonPreview
{
    <#
    .SYNOPSIS
        Recursively truncate string fields and arrays in an object tree to
        produce a token-light, structurally-faithful preview.

    .DESCRIPTION
        Walks any pscustomobject / hashtable / array tree.  Strings exceeding
        MaxFieldChars are truncated according to PreviewMode; arrays exceeding
        MaxArrayItems are clipped with a `[+N more items]` marker.  Structure
        is preserved — only leaf values shrink, so the output is still
        JSON-shaped and inspection-friendly.

        Modes:
            Head      First N chars + `... [+M more chars]`
            Tail      `[+M more chars] ...` + last N chars
            Middle    Centred slice + markers on both sides
            Sandwich  N/2 head + `... [+M more chars] ...` + N/2 tail
            Auto      Heuristic by length:
                          <= MaxFieldChars     → no truncation
                          <= 4*MaxFieldChars   → Head
                          else                  → Sandwich

        For arbitrary slicing pass -PreviewWindow @{ Start=N; Length=M }
        (overrides PreviewMode for string truncation; arrays still honour
        MaxArrayItems).

        Module-level defaults are read from `$script:JsoPreviewMaxFieldChars`,
        `$script:JsoPreviewMaxArrayItems`, `$script:JsoPreviewMode`.

    .PARAMETER InputObject
        The object to truncate.  May be any tree of pscustomobject, hashtable,
        IList, string, number, boolean, or null.

    .PARAMETER MaxFieldChars
        Per-string truncation budget.  Default reads $script:JsoPreviewMaxFieldChars.

    .PARAMETER MaxArrayItems
        Per-array truncation budget.  Default reads $script:JsoPreviewMaxArrayItems.

    .PARAMETER PreviewMode
        Truncation strategy: Head, Tail, Middle, Sandwich, Auto.
        Default reads $script:JsoPreviewMode.

    .PARAMETER PreviewWindow
        Hashtable @{ Start = <int>; Length = <int> }.  When supplied, every
        long string is sliced via that window regardless of PreviewMode.

    .EXAMPLE
        $record | ConvertTo-JsonPreview -MaxFieldChars 200

    .EXAMPLE
        $record | ConvertTo-JsonPreview -PreviewMode Sandwich -MaxFieldChars 100

    .EXAMPLE
        $record | ConvertTo-JsonPreview -PreviewWindow @{ Start = 1000; Length = 200 }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object]$InputObject,

        [int]$MaxFieldChars = $script:JsoPreviewMaxFieldChars,

        [int]$MaxArrayItems = $script:JsoPreviewMaxArrayItems,

        [ValidateSet('Head', 'Tail', 'Middle', 'Sandwich', 'Auto')]
        [string]$PreviewMode = $script:JsoPreviewMode,

        [hashtable]$PreviewWindow
    )

    process
    {
        # --- Local helpers (closure-captured params) ---

        function _TruncateString
        {
            param([string]$s)

            if ($null -eq $s) { return $s }
            $len = $s.Length
            if ($len -le $MaxFieldChars -and -not $PreviewWindow) { return $s }

            # Explicit window overrides everything
            if ($PreviewWindow)
            {
                $start = [int]$PreviewWindow['Start']
                $length = [int]$PreviewWindow['Length']
                if ($start -lt 0) { $start = 0 }
                if ($start -ge $len) { return "[empty window: start past end]" }
                if ($length -le 0 -or ($start + $length) -gt $len) { $length = $len - $start }
                $slice = $s.Substring($start, $length)
                $head = if ($start -gt 0) { "[+$start chars] ..." } else { '' }
                $tailRem = $len - $start - $length
                $tail = if ($tailRem -gt 0) { "... [+$tailRem more chars]" } else { '' }
                return ($head + $slice + $tail)
            }

            # Resolve Auto → concrete mode
            $mode = $PreviewMode
            if ($mode -eq 'Auto')
            {
                if ($len -le (4 * $MaxFieldChars)) { $mode = 'Head' }
                else { $mode = 'Sandwich' }
            }

            switch ($mode)
            {
                'Head'
                {
                    $rem = $len - $MaxFieldChars
                    return $s.Substring(0, $MaxFieldChars) + "... [+$rem more chars]"
                }
                'Tail'
                {
                    $rem = $len - $MaxFieldChars
                    return "[+$rem more chars] ..." + $s.Substring($len - $MaxFieldChars)
                }
                'Middle'
                {
                    $start = [int](($len - $MaxFieldChars) / 2)
                    $left = $start
                    $right = $len - $start - $MaxFieldChars
                    return "[+$left chars] ..." + $s.Substring($start, $MaxFieldChars) + "... [+$right more chars]"
                }
                'Sandwich'
                {
                    $half = [int]($MaxFieldChars / 2)
                    $rem = $len - (2 * $half)
                    if ($rem -le 0) { return $s }
                    return $s.Substring(0, $half) + "... [+$rem more chars] ..." + $s.Substring($len - $half)
                }
            }
            return $s
        }

        function _Walk
        {
            param([object]$o)

            if ($null -eq $o) { return $null }

            if ($o -is [string])
            {
                return _TruncateString $o
            }

            if ($o -is [System.Collections.IDictionary])
            {
                $newMap = [ordered]@{}
                foreach ($key in $o.Keys) { $newMap[$key] = _Walk $o[$key] }
                return [pscustomobject]$newMap
            }

            if ($o -is [System.Management.Automation.PSCustomObject])
            {
                $newObj = [ordered]@{}
                foreach ($prop in $o.PSObject.Properties)
                {
                    $newObj[$prop.Name] = _Walk $prop.Value
                }
                return [pscustomobject]$newObj
            }

            if ($o -is [System.Collections.IEnumerable])
            {
                $items = @($o)
                $count = $items.Count
                if ($count -le $MaxArrayItems)
                {
                    return @($items | ForEach-Object { _Walk $_ })
                }
                $kept = $items[0..($MaxArrayItems - 1)] | ForEach-Object { _Walk $_ }
                $omitted = $count - $MaxArrayItems
                return @(@($kept) + "[+$omitted more items]")
            }

            # Numbers, booleans, etc. — pass through
            return $o
        }

        return _Walk $InputObject
    }
}

#endregion

#region --- Read-Side Convenience ---

# =============================================================================
# READ-SIDE CONVENIENCE — quick-path one-liners over JSONL files.
# All functions emit pscustomobject (or scalar values for path projection)
# and stream where possible.  Index-aware where it pays off (single-record
# random access, tail).  Falls back to streaming when no .jidx is present.
#
# Index path convention: looks for a sibling `<Path>.jidx`.  Override via
# -IndexPath when the index lives elsewhere.
# =============================================================================

function Get-JsonlRecordCount
{
    <#
    .SYNOPSIS
        Count records in a JSONL file.  O(1) when a .jidx index is present,
        O(n) line-count fallback otherwise.

    .PARAMETER Path
        Path to the JSONL file.

    .PARAMETER IndexPath
        Optional override for the .jidx sidecar location.  Defaults to
        `<Path>.jidx`.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$IndexPath = "$Path.jidx"
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Get-JsonlRecordCount: file not found: $Path"
    }

    if ([System.IO.File]::Exists($IndexPath))
    {
        try
        {
            $idx = [JsonlIndex]::new($IndexPath)
            return $idx.LineCount
        }
        catch { Write-Verbose "Index unreadable, falling back to line count: $_" }
    }

    $count = 0
    $sr = [System.IO.StreamReader]::new($Path)
    try
    {
        while ($null -ne $sr.ReadLine()) { $count++ }
    }
    finally { $sr.Dispose() }
    return $count
}


function Get-JsonlRecord
{
    <#
    .SYNOPSIS
        Read a single record from a JSONL file by 0-based index.

    .DESCRIPTION
        Uses the .jidx index for O(1) seek when available; falls back to
        streaming with skip-to-N otherwise.  Returns one pscustomobject.

    .PARAMETER Path
        Path to the JSONL file.

    .PARAMETER At
        0-based record index.

    .PARAMETER IndexPath
        Optional override for the .jidx sidecar location.  Defaults to
        `<Path>.jidx`.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int]$At,

        [string]$IndexPath = "$Path.jidx"
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Get-JsonlRecord: file not found: $Path"
    }
    if ($At -lt 0) { throw "Get-JsonlRecord: -At must be >= 0 (got $At)" }

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
    if ($idx)
    {
        if ($At -ge $idx.LineCount)
        {
            $fs.Dispose()
            throw "Get-JsonlRecord: -At $At out of range (file has $($idx.LineCount) records)"
        }
        $fs.Position = $idx.GetOffset($At)
    }

    $sr = [System.IO.StreamReader]::new($fs, [System.Text.UTF8Encoding]::new($false))
    try
    {
        if ($idx)
        {
            $line = $sr.ReadLine()
            return ($line | ConvertFrom-Json)
        }

        $i = 0
        while ($null -ne ($line = $sr.ReadLine()))
        {
            if ($i -eq $At)
            {
                $trimmed = $line.Trim()
                if ($trimmed.Length -eq 0) { return $null }
                return ($trimmed | ConvertFrom-Json)
            }
            $i++
        }
        throw "Get-JsonlRecord: -At $At out of range (file has $i records)"
    }
    finally
    {
        $sr.Dispose()
    }
}


function Get-JsonlHead
{
    <#
    .SYNOPSIS
        Stream the first N records from a JSONL file as pscustomobjects.

    .PARAMETER Path
        Path to the JSONL file.

    .PARAMETER Count
        Number of records.  Default 10.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Count = 10
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Get-JsonlHead: file not found: $Path"
    }
    if ($Count -le 0) { return }

    $fs = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $sr = [System.IO.StreamReader]::new($fs, [System.Text.UTF8Encoding]::new($false))
    try
    {
        $emitted = 0
        while ($emitted -lt $Count -and $null -ne ($line = $sr.ReadLine()))
        {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0) { continue }
            try
            {
                $obj = $trimmed | ConvertFrom-Json
            }
            catch { continue }
            Write-Output $obj
            $emitted++
        }
    }
    finally { $sr.Dispose() }
}


function Get-JsonlTail
{
    <#
    .SYNOPSIS
        Read the last N records from a JSONL file as pscustomobjects.

    .DESCRIPTION
        Uses the .jidx index for O(1) seek when available; falls back to a
        circular buffer over streaming when no index is present.

    .PARAMETER Path
        Path to the JSONL file.

    .PARAMETER Count
        Number of trailing records.  Default 10.

    .PARAMETER IndexPath
        Optional override for the .jidx sidecar location.  Defaults to
        `<Path>.jidx`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Count = 10,

        [string]$IndexPath = "$Path.jidx"
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Get-JsonlTail: file not found: $Path"
    }
    if ($Count -le 0) { return }

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

    if ($idx)
    {
        $start = [math]::Max(0, $idx.LineCount - $Count)
        $fs = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $fs.Position = $idx.GetOffset($start)
        $sr = [System.IO.StreamReader]::new($fs, [System.Text.UTF8Encoding]::new($false))
        try
        {
            while ($null -ne ($line = $sr.ReadLine()))
            {
                $trimmed = $line.Trim()
                if ($trimmed.Length -eq 0) { continue }
                try { Write-Output ($trimmed | ConvertFrom-Json) } catch { continue }
            }
        }
        finally { $sr.Dispose() }
        return
    }

    # No index — circular buffer fallback
    $buffer = [System.Collections.Generic.Queue[string]]::new()
    $sr = [System.IO.StreamReader]::new($Path)
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0) { continue }
            if ($buffer.Count -ge $Count) { [void]$buffer.Dequeue() }
            $buffer.Enqueue($trimmed)
        }
    }
    finally { $sr.Dispose() }

    foreach ($entry in $buffer)
    {
        try { Write-Output ($entry | ConvertFrom-Json) } catch { continue }
    }
}


function Read-Jsonl
{
    <#
    .SYNOPSIS
        Stream every record in a JSONL file as pscustomobjects.

    .DESCRIPTION
        Whole-file convenience reader.  Emits one pscustomobject per record,
        skipping blank lines and silently dropping malformed lines (use
        Test-Jsonl in jso-debug for validation reporting).  Streams without
        accumulating, so safe on large files when piped through `Where-Object`
        or `ForEach-Object`.

    .PARAMETER Path
        Path to the JSONL file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Read-Jsonl: file not found: $Path"
    }

    $sr = [System.IO.StreamReader]::new($Path)
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0) { continue }
            try { Write-Output ($trimmed | ConvertFrom-Json) } catch { continue }
        }
    }
    finally { $sr.Dispose() }
}


function Select-JsonlPath
{
    <#
    .SYNOPSIS
        Project values at a dotted JSON path across every record in a JSONL file.

    .DESCRIPTION
        Path syntax matches what JsonlSchema produces:
            field            top-level field
            a.b.c            nested fields
            arr[]            iterate array elements
            arr[].field      nested in each array element

        Emits one value per match.  Records without the path contribute
        nothing.  Streams without accumulating.

    .PARAMETER Path
        Path to the JSONL file.

    .PARAMETER JsonPath
        Dotted JSON path with `[]` for array iteration.

    .EXAMPLE
        Select-JsonlPath -Path .\thread.jsonl -JsonPath '_xid'
        # → flat sequence of all exchange IDs

    .EXAMPLE
        Select-JsonlPath -Path .\thread.jsonl -JsonPath 'records[].text'
        # → flat sequence of every record's text across every exchange
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$JsonPath
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Select-JsonlPath: file not found: $Path"
    }

    # Parse path into a sequence of operations: Descend(field) or IterateArray
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
                $val = $null
                if ($obj -is [System.Management.Automation.PSCustomObject])
                {
                    $prop = $obj.PSObject.Properties[$field]
                    if ($null -ne $prop) { $val = $prop.Value }
                    else { return }
                }
                elseif ($obj -is [System.Collections.IDictionary])
                {
                    if (-not $obj.Contains($field)) { return }
                    $val = $obj[$field]
                }
                else { return }
                _WalkPath -obj $val -segIndex ($segIndex + 1)
            }
            'IterateArray'
            {
                if ($obj -is [string]) { return }   # don't iterate string chars
                if ($obj -is [System.Collections.IEnumerable])
                {
                    foreach ($item in $obj) { _WalkPath -obj $item -segIndex ($segIndex + 1) }
                }
            }
        }
    }

    $sr = [System.IO.StreamReader]::new($Path)
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0) { continue }
            try { $obj = $trimmed | ConvertFrom-Json }
            catch { continue }
            _WalkPath -obj $obj -segIndex 0
        }
    }
    finally { $sr.Dispose() }
}

#endregion

#region --- Hash Sidecar ---

# =============================================================================
# HASH SIDECAR — per-record content-hash sidecar files for fast diff and
# dedup workflows. Sidecar format mirrors .jidx layout:
#
#   Magic    : "JSHA" (4 bytes ASCII)
#   Version  : int32 = 1
#   Count    : int32 = number of records
#   Hashes   : count × int64 (Get-ContentFingerprint output, one per record line)
#
# Depends on Get-ContentFingerprint from jso-hash.ps1 — caller must dot-source
# both files. Functions throw a descriptive error if the hash primitive
# is unavailable.
# =============================================================================

function _Assert-HashAvailable
{
    if (-not (Get-Command Get-ContentFingerprint -CommandType Function -ErrorAction SilentlyContinue))
    {
        throw "Get-ContentFingerprint not available — dot-source jso-hash.ps1 before using hash-sidecar functions."
    }
}


function New-JsonlHashIndex
{
    <#
    .SYNOPSIS
        Build a `<Path>.hash` sidecar containing one Rabin-Karp content hash
        per record line.

    .DESCRIPTION
        Streams the file and applies Get-ContentFingerprint to each non-blank line,
        writing the result as a JSHA-magic binary sidecar. Used by
        Compare-JsonlByHash (in jso-debug) for O(load) diff against another
        sidecar instead of O(re-parse) record-by-record comparison.

    .PARAMETER Path
        Path to the JSONL file.

    .PARAMETER IndexPath
        Optional override for the sidecar location. Defaults to `<Path>.hash`.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$IndexPath = "$Path.hash"
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "New-JsonlHashIndex: file not found: $Path"
    }
    _Assert-HashAvailable

    $hashes = [System.Collections.Generic.List[long]]::new()
    $sr = [System.IO.StreamReader]::new($Path)
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            $hashes.Add([long](Get-ContentFingerprint -Content $line))
        }
    }
    finally { $sr.Dispose() }

    $fs = [System.IO.FileStream]::new(
        $IndexPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write
    )
    $bw = [System.IO.BinaryWriter]::new($fs)
    try
    {
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('JSHA'))
        $bw.Write([int]1)
        $bw.Write([int]$hashes.Count)
        foreach ($h in $hashes) { $bw.Write([long]$h) }
    }
    finally
    {
        $bw.Dispose()
        $fs.Dispose()
    }

    return [pscustomobject]@{
        IndexPath = $IndexPath
        LineCount = $hashes.Count
        SizeBytes = [int](12 + 8 * $hashes.Count)
    }
}


function Test-JsonlHashIndex
{
    <#
    .SYNOPSIS
        Verify that a `<Path>.hash` sidecar matches the current JSONL file.

    .DESCRIPTION
        Reads the sidecar, re-hashes the JSONL line by line, returns $true
        only when every hash matches and the line count is identical.
        Returns $false on length mismatch, hash drift, or missing/invalid
        sidecar.

    .PARAMETER Path
        Path to the JSONL file.

    .PARAMETER IndexPath
        Optional override for the sidecar location. Defaults to `<Path>.hash`.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$IndexPath = "$Path.hash"
    )

    if (-not [System.IO.File]::Exists($Path)) { return $false }
    if (-not [System.IO.File]::Exists($IndexPath)) { return $false }
    _Assert-HashAvailable

    # Read sidecar
    $stored = $null
    $count = 0
    $fs = [System.IO.FileStream]::new(
        $IndexPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $br = [System.IO.BinaryReader]::new($fs)
    try
    {
        if ($fs.Length -lt 12) { return $false }
        $magic = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
        if ($magic -ne 'JSHA') { return $false }
        $ver = $br.ReadInt32()
        if ($ver -ne 1) { return $false }
        $count = $br.ReadInt32()
        $stored = [long[]]::new($count)
        for ($i = 0; $i -lt $count; $i++) { $stored[$i] = $br.ReadInt64() }
    }
    finally
    {
        $br.Dispose()
        $fs.Dispose()
    }

    # Re-hash and compare
    $i = 0
    $sr = [System.IO.StreamReader]::new($Path)
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            if ($i -ge $count) { return $false }
            $h = [long](Get-ContentFingerprint -Content $line)
            if ($h -ne $stored[$i]) { return $false }
            $i++
        }
    }
    finally { $sr.Dispose() }

    return ($i -eq $count)
}


function Get-ExchangeContentHash
{
    <#
    .SYNOPSIS
        Compute a canonical content hash for an exchange envelope.

    .DESCRIPTION
        Extracts text from `prompt` and `response` records, trims each, joins
        with a stable separator, and hashes via Get-ContentFingerprint. The result
        is a deterministic dedup key suitable for cross-source comparison
        (claude-jso vs perplexity-side envelopes whose `records[]` contain
        the same prompt+response pair will produce the same hash).

        Recognises both the underscore-prefixed claude-jso shape (`_type`,
        `text` on records) and the unprefixed shared-envelope draft (`type`,
        `text`). Citations records and tool-call records are deliberately
        excluded — only prompt/response text contributes, so the hash stays
        stable across re-imports that may add or refresh citations.

    .PARAMETER Envelope
        An exchange envelope pscustomobject (one record from an exchanges
        JSONL file).
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Envelope
    )

    process
    {
        _Assert-HashAvailable

        $records = $null
        if ($null -ne $Envelope.PSObject.Properties['records']) { $records = $Envelope.records }

        $parts = [System.Collections.Generic.List[string]]::new()
        if ($records)
        {
            foreach ($r in $records)
            {
                $type = ''
                if ($null -ne $r.PSObject.Properties['_type']) { $type = [string]$r._type }
                elseif ($null -ne $r.PSObject.Properties['type']) { $type = [string]$r.type }
                if ($type -ne 'prompt' -and $type -ne 'response') { continue }

                if ($null -ne $r.PSObject.Properties['text'] -and $null -ne $r.text)
                {
                    $t = ([string]$r.text).Trim()
                    if ($t) { $parts.Add($t) }
                }
            }
        }

        $canonical = $parts -join "`n---`n"
        if ([string]::IsNullOrEmpty($canonical)) { return 0L }
        return [long](Get-ContentFingerprint -Content $canonical)
    }
}

#endregion

#region --- Write-Side Helpers ---

# =============================================================================
# WRITE-SIDE HELPERS
# These operate on PSCustomObject (the serialization boundary).
# Read path (JsonlTraversal, JsonlIndex) never touches PSCustomObject.
# =============================================================================

function Get-JsonDepth
{
    # Recursively compute the minimum depth required for a lossless ConvertTo-Json
    # round-trip. Never hardcode a depth magic number — always call this first.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    function Get-Depth
    {
        param(
            $obj,
            [int]$currentDepth = 0
        )

        if ($obj -is [PSCustomObject] -or $obj -is [System.Collections.IDictionary])
        {
            $maxChildDepth = $currentDepth + 1
            if ($obj -is [System.Collections.IDictionary])
            {
                foreach ($val in $obj.Values)
                {
                    $childDepth = Get-Depth -obj $val -currentDepth ($currentDepth + 1)
                    if ($childDepth -gt $maxChildDepth) { $maxChildDepth = $childDepth }
                }
            }
            else
            {
                foreach ($prop in $obj.PSObject.Properties)
                {
                    $childDepth = Get-Depth -obj $prop.Value -currentDepth ($currentDepth + 1)
                    if ($childDepth -gt $maxChildDepth) { $maxChildDepth = $childDepth }
                }
            }
            return $maxChildDepth
        }

        if ($obj -is [System.Array] -or $obj -is [System.Collections.IList])
        {
            $maxChildDepth = $currentDepth + 1
            foreach ($item in $obj)
            {
                $childDepth = Get-Depth -obj $item -currentDepth ($currentDepth + 1)
                if ($childDepth -gt $maxChildDepth) { $maxChildDepth = $childDepth }
            }
            return $maxChildDepth
        }

        return $currentDepth
    }

    $isContainer =
    $InputObject -is [PSCustomObject] -or
    $InputObject -is [System.Collections.IDictionary] -or
    $InputObject -is [System.Array] -or
    $InputObject -is [System.Collections.IList]

    $startingDepth = if ($isContainer) { -1 } else { 0 }
    return Get-Depth -obj $InputObject -currentDepth $startingDepth
}


function ConvertTo-CanonicalJson
{
    # Serialize a PSCustomObject or hashtable to JSON using the minimum lossless
    # depth — never a hardcoded magic number. Use -Compress for JSONL output.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$InputObject,

        [switch]$Compress
    )
    process
    {
        $depth = Get-JsonDepth -InputObject $InputObject
        if ($Compress)
        {
            return $InputObject | ConvertTo-Json -Depth $depth -Compress
        }
        else
        {
            return $InputObject | ConvertTo-Json -Depth $depth
        }
    }
}


function Merge-JsonObjects
{
    # Shallow merge two PSCustomObjects. Right-wins on key collision.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Base,

        [Parameter(Mandatory)]
        [PSCustomObject]$Overlay
    )

    $merged = [PSCustomObject]@{}

    foreach ($prop in $Base.PSObject.Properties)
    {
        $merged | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
    }
    foreach ($prop in $Overlay.PSObject.Properties)
    {
        if ($merged.PSObject.Properties[$prop.Name])
        {
            $merged.PSObject.Properties[$prop.Name].Value = $prop.Value
        }
        else
        {
            $merged | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
        }
    }

    return $merged
}


# =============================================================================
# BLOOM FILTER
# Probabilistic pre-filter for deduplication. No false negatives guaranteed.
# ALWAYS pair Test-BloomFilterItem with an exact HashSet check on $true return:
#
#   if (Test-BloomFilterItem -BloomFilter $bf -Item $key) {
#       if ($seenKeys.Contains($key)) { <confirmed duplicate> }
#   } else {
#       Add-BloomFilterItem -BloomFilter $bf -Item $key
#       [void]$seenKeys.Add($key)
#   }
#
# Sizing is mathematically correct: m and k derived from ExpectedItems and
# FalsePositiveRate. Hash function is double-hashing (FNV-1 + djb2).
# =============================================================================

function New-BloomFilter
{
    [CmdletBinding()]
    param(
        [int]$ExpectedItems = 10000,
        [double]$FalsePositiveRate = 0.01
    )

    $m = [Math]::Ceiling(
        ($ExpectedItems * [Math]::Log($FalsePositiveRate)) /
        [Math]::Log(1 / [Math]::Pow(2, [Math]::Log(2)))
    )
    $k = [Math]::Ceiling(($m / $ExpectedItems) * [Math]::Log(2))

    return [PSCustomObject]@{
        PSTypeName        = 'Jso.BloomFilter'
        BitArray          = [System.Collections.BitArray]::new([int]$m)
        Size              = [int]$m
        HashCount         = [int]$k
        ItemCount         = 0
        ExpectedItems     = $ExpectedItems
        FalsePositiveRate = $FalsePositiveRate
    }
}


function script:Get-BloomFilterHashes
{
    # Internal: double-hashing (FNV-1 + djb2) to generate k independent hashes.
    param(
        [string]$Item,
        [int]$HashCount,
        [int]$Size
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Item)

    [uint64]$modulus = 4294967296

    [uint64]$hash1 = 2166136261
    foreach ($byte in $bytes)
    {
        $hash1 = ((($hash1 -bxor [uint64]$byte) * 16777619) % $modulus)
    }

    [uint64]$hash2 = 5381
    foreach ($byte in $bytes)
    {
        $hash2 = ((($hash2 * 33) + [uint64]$byte) % $modulus)
    }

    $hashes = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $HashCount; $i++)
    {
        $combined = ($hash1 + ([uint64]$i * $hash2)) % [uint64]$Size
        $hashes.Add([int]$combined)
    }
    return $hashes
}


function Add-BloomFilterItem
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$BloomFilter,

        [Parameter(Mandatory)]
        [string]$Item
    )
    $hashes = script:Get-BloomFilterHashes -Item $Item -HashCount $BloomFilter.HashCount -Size $BloomFilter.Size
    foreach ($hash in $hashes) { $BloomFilter.BitArray[$hash] = $true }
    $BloomFilter.ItemCount++
}


function Test-BloomFilterItem
{
    # Returns $false = definitely not in set. Returns $true = probably in set.
    # Caller MUST verify with exact HashSet check on $true (see module header).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$BloomFilter,

        [Parameter(Mandatory)]
        [string]$Item
    )
    $hashes = script:Get-BloomFilterHashes -Item $Item -HashCount $BloomFilter.HashCount -Size $BloomFilter.Size
    foreach ($hash in $hashes)
    {
        if (-not $BloomFilter.BitArray[$hash]) { return $false }
    }
    return $true
}


function Add-BloomFilterFromJsonl
{
    <#
    .SYNOPSIS
        Bulk-add JSONL-derived keys to an existing Bloom filter.

    .DESCRIPTION
        Streams a JSONL file and adds either projected JsonPath values or
        canonical exchange content hashes to the supplied Bloom filter.  The
        filter object is mutated in place and returned for pipeline-friendly
        chaining.

        JsonPath projection uses Select-JsonlPath, so it supports the same
        dotted syntax and [] array iteration as the schema probe paths.

        -ContentHash uses Get-ExchangeContentHash and therefore requires
        jso-hash.ps1 to have been dot-sourced as well.
    #>
    [CmdletBinding(DefaultParameterSetName = 'JsonPath')]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$BloomFilter,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'JsonPath')]
        [string]$JsonPath,

        [Parameter(Mandatory, ParameterSetName = 'ContentHash')]
        [switch]$ContentHash
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Add-BloomFilterFromJsonl: file not found: $Path"
    }

    if ($PSCmdlet.ParameterSetName -eq 'ContentHash')
    {
        _Assert-HashAvailable
        foreach ($record in (Read-Jsonl -Path $Path))
        {
            $hash = [string](Get-ExchangeContentHash -Envelope $record)
            if ($hash) { Add-BloomFilterItem -BloomFilter $BloomFilter -Item $hash }
        }
        return $BloomFilter
    }

    foreach ($value in (Select-JsonlPath -Path $Path -JsonPath $JsonPath))
    {
        if ($null -eq $value) { continue }
        Add-BloomFilterItem -BloomFilter $BloomFilter -Item ([string]$value)
    }

    return $BloomFilter
}


function Save-BloomFilter
{
    <#
    .SYNOPSIS
        Persist a Bloom filter to a compact .bloom binary sidecar.

    .DESCRIPTION
        Sidecar format:
            Magic "JSBF" + version int32 + size int32 + hashCount int32
            + itemCount int32 + expectedItems int32 + falsePositiveRate double
            + byteLength int32 + packed BitArray bytes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$BloomFilter,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $byteLength = [int][math]::Ceiling($BloomFilter.Size / 8.0)
    $bytes = [byte[]]::new($byteLength)
    $BloomFilter.BitArray.CopyTo($bytes, 0)

    $fs = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write
    )
    $bw = [System.IO.BinaryWriter]::new($fs)
    try
    {
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('JSBF'))
        $bw.Write([int]1)
        $bw.Write([int]$BloomFilter.Size)
        $bw.Write([int]$BloomFilter.HashCount)
        $bw.Write([int]$BloomFilter.ItemCount)
        $bw.Write([int]$BloomFilter.ExpectedItems)
        $bw.Write([double]$BloomFilter.FalsePositiveRate)
        $bw.Write([int]$byteLength)
        $bw.Write($bytes)
    }
    finally
    {
        $bw.Dispose()
        $fs.Dispose()
    }

    return [pscustomobject]@{
        Path              = $Path
        Size              = [int]$BloomFilter.Size
        HashCount         = [int]$BloomFilter.HashCount
        ItemCount         = [int]$BloomFilter.ItemCount
        ExpectedItems     = [int]$BloomFilter.ExpectedItems
        FalsePositiveRate = [double]$BloomFilter.FalsePositiveRate
        SizeBytes         = [System.IO.FileInfo]::new($Path).Length
    }
}


function Read-BloomFilter
{
    <#
    .SYNOPSIS
        Restore a Bloom filter saved by Save-BloomFilter.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Read-BloomFilter: file not found: $Path"
    }

    $fs = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $br = [System.IO.BinaryReader]::new($fs)
    try
    {
        if ($fs.Length -lt 32) { throw "Invalid Bloom sidecar: too small" }
        $magic = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
        if ($magic -ne 'JSBF') { throw "Invalid Bloom sidecar magic: '$magic'" }
        $version = $br.ReadInt32()
        if ($version -ne 1) { throw "Unsupported Bloom sidecar version: $version" }

        $size = $br.ReadInt32()
        $hashCount = $br.ReadInt32()
        $itemCount = $br.ReadInt32()
        $expectedItems = $br.ReadInt32()
        $falsePositiveRate = $br.ReadDouble()
        $byteLength = $br.ReadInt32()
        $bytes = $br.ReadBytes($byteLength)
    }
    finally
    {
        $br.Dispose()
        $fs.Dispose()
    }

    $bitArray = [System.Collections.BitArray]::new($bytes)
    $bitArray.Length = $size

    return [PSCustomObject]@{
        PSTypeName        = 'Jso.BloomFilter'
        BitArray          = $bitArray
        Size              = [int]$size
        HashCount         = [int]$hashCount
        ItemCount         = [int]$itemCount
        ExpectedItems     = [int]$expectedItems
        FalsePositiveRate = [double]$falsePositiveRate
    }
}

#endregion

#region --- New-JsonlSnapshot ---

function New-JsonlSnapshot
{
    <#
    .SYNOPSIS
        Phase 1 ingest: snapshot a source JSONL into a working directory.
    .DESCRIPTION
        Copies the source JSONL to $WorkingDir with LF-normalized line endings,
        validates the tail line parses as JSON (truncates if mid-write race),
        and builds a .jidx binary seek index alongside the snapshot.

        After this call, the source file is never touched again for this run.
    .PARAMETER SourcePath
        Path to the live/source JSONL file.
    .PARAMETER WorkingDir
        Directory to write the snapshot and .jidx into. Created if absent.
    .PARAMETER FileName
        Override the snapshot filename. Defaults to the source filename.
    .OUTPUTS
        PSCustomObject with SnapshotPath, IndexPath, LineCount, SnapshotMeta.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [string]$FileName
    )

    if (-not [System.IO.File]::Exists($SourcePath))
    {
        throw "Source JSONL not found: $SourcePath"
    }

    if (-not [System.IO.Directory]::Exists($WorkingDir))
    {
        [void][System.IO.Directory]::CreateDirectory($WorkingDir)
    }

    if (-not $FileName)
    {
        $FileName = [System.IO.Path]::GetFileName($SourcePath)
    }

    $snapshotPath = [System.IO.Path]::Combine($WorkingDir, $FileName)
    $indexPath = [System.IO.Path]::ChangeExtension($snapshotPath, '.jidx')
    $snapshotStarted = [datetime]::UtcNow

    # --- Copy with LF normalization ---
    $encoding = [System.Text.UTF8Encoding]::new($false)  # no BOM
    [int]$lineCount = 0
    [string]$lastLine = $null

    $srcFs = [System.IO.FileStream]::new(
        $SourcePath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read   # allow writer to keep writing
    )
    $srcReader = [System.IO.StreamReader]::new($srcFs, $encoding)

    $dstFs = [System.IO.FileStream]::new(
        $snapshotPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write
    )

    try
    {
        while ($null -ne ($line = $srcReader.ReadLine()))
        {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0) { continue }

            # Write line bytes + LF directly to avoid StreamWriter overhead
            $lineBytes = $encoding.GetBytes($trimmed)
            $dstFs.Write($lineBytes, 0, $lineBytes.Length)
            $dstFs.WriteByte(0x0A)  # LF

            $lineCount++
            $lastLine = $trimmed
        }
    }
    finally
    {
        $dstFs.Dispose()
        $srcReader.Dispose()
        $srcFs.Dispose()
    }

    # --- Tail validation: ensure last line is valid JSON ---
    if ($lastLine)
    {
        $tailValid = $true
        try
        {
            [void][System.Text.Json.JsonSerializer]::Deserialize($lastLine, [System.Text.Json.JsonElement])
        }
        catch { $tailValid = $false }

        if (-not $tailValid)
        {
            # Truncate the snapshot to remove the incomplete last line
            $lineCount--
            if ($lineCount -gt 0)
            {
                $truncFs = [System.IO.FileStream]::new(
                    $snapshotPath,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::ReadWrite
                )
                try
                {
                    [long]$newLength = 0
                    for ([long]$pos = $truncFs.Length - 2; $pos -ge 0; $pos--)
                    {
                        $truncFs.Position = $pos
                        if ($truncFs.ReadByte() -eq 0x0A)
                        {
                            $newLength = $pos + 1
                            break
                        }
                    }
                    $truncFs.SetLength($newLength)
                }
                finally { $truncFs.Dispose() }
            }
            else
            {
                # No valid lines at all — empty snapshot
                [System.IO.File]::WriteAllText($snapshotPath, '')
            }
        }
    }

    # --- Build .jidx via the shared index writer ---
    $idx = [JsonlIndex]::Build($snapshotPath, $indexPath)

    $sourceLastWrite = [System.IO.File]::GetLastWriteTimeUtc($SourcePath)

    return [pscustomobject]@{
        SnapshotPath = $snapshotPath
        IndexPath    = $indexPath
        LineCount    = $idx.LineCount
        SnapshotMeta = [pscustomobject]@{
            SourcePath        = $SourcePath
            SnapshotStartedAt = $snapshotStarted.ToString('o')
            SourceLastWrite   = $sourceLastWrite.ToString('o')
        }
    }
}

#endregion

#region --- Claude Config Root ---

function Get-ClaudeConfigRootCandidate
{
    <#
    .SYNOPSIS
        Conventional Claude Code config root locations, most likely first.
    .DESCRIPTION
        Built at call time from the OS-reported user home. Holds no absolute
        path literal: only the directory NAMES that are Claude Code's own
        storage convention, joined onto a home the operating system reports.
        That is the difference between a convention and a hard-coded path — this
        list is identical on every machine and every user account.

        Order is by likelihood, not preference: Claude Code's default location
        first, XDG-style installs after.
    .OUTPUTS
        [string[]] candidate paths. Empty if no home directory can be determined.
    #>
    [CmdletBinding()]
    param()

    $candidates = [System.Collections.Generic.List[string]]::new()

    # Ask the OS, not the environment. $env:USERPROFILE / $env:HOME are
    # backstops for hosts where GetFolderPath returns empty.
    $userHome = [System.Environment]::GetFolderPath('UserProfile')
    if (-not $userHome) { $userHome = $env:USERPROFILE }
    if (-not $userHome) { $userHome = $env:HOME }

    if ($userHome)
    {
        $candidates.Add([System.IO.Path]::Combine($userHome, '.claude'))
    }

    if ($env:XDG_CONFIG_HOME)
    {
        $candidates.Add([System.IO.Path]::Combine($env:XDG_CONFIG_HOME, 'claude'))
    }

    if ($userHome)
    {
        $candidates.Add([System.IO.Path]::Combine($userHome, '.config', 'claude'))
    }

    # Normalize separators — XDG_CONFIG_HOME is commonly written with forward
    # slashes, and these paths surface verbatim in "probed:" error messages.
    for ($i = 0; $i -lt $candidates.Count; $i++)
    {
        $candidates[$i] = [System.IO.Path]::GetFullPath($candidates[$i])
    }

    return $candidates.ToArray()
}


function Get-ClaudeConfigRoot
{
    <#
    .SYNOPSIS
        Discover Claude Code's config root without depending on an env var.
    .DESCRIPTION
        Everything this toolkit reads (transcripts under projects/) and writes
        (run artifacts under tmp/) hangs off a single root directory. That root
        used to be read straight from $env:CLAUDE_CONFIG_DIR — which is empty in
        most agent shells, and [Path]::Combine('', 'tmp') returns the RELATIVE
        path 'tmp', so working directories silently materialised under whatever
        the current directory happened to be.

        Discovery replaces that assumption, in strict order:

            1. -ConfigRoot                (explicit caller override)
            2. $env:CLAUDE_CONFIG_DIR     (Claude Code's own variable)
            3. $env:CLAUDE_HOME           (this environment's pin)
            4. probed conventional roots  (Get-ClaudeConfigRootCandidate)

        Sources 1-3 are authoritative: when one is supplied it is meant to be
        correct, so a bad value throws rather than falling through to a probe.
        Quietly ignoring an explicit root would hide the very misconfiguration
        the caller was trying to state.

        The env vars are an accelerator, never a requirement. Variables declared
        in Claude Code's settings.json exist only inside Claude Code sessions —
        a cron job, a bare pwsh shell, or another agent runtime sees none of
        them, which is exactly why the probe stays.

        Every candidate must prove itself on disk before it is returned — with
        -RequireProjects, by actually containing projects/. A guess that cannot
        be corroborated is rejected, never returned. No result is cached: the
        probe is a handful of directory-existence checks, and staleness would
        cost more than it saves.
    .PARAMETER ConfigRoot
        Explicit root. Skips discovery entirely; throws if it does not qualify.
    .PARAMETER RequireProjects
        Demand a root that actually holds transcripts — one containing a
        projects/ subdirectory — and throw if no candidate does. Read paths want
        this. Write paths (scratch and output roots) do not: they need only a
        real base directory, and fall back to the conventional location so that
        a first run on a fresh machine still creates an absolute, predictable
        directory instead of a relative one.
    .OUTPUTS
        [string] absolute path to the Claude config root.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigRoot,
        [switch]$RequireProjects
    )

    # Subdirectory a candidate must contain to qualify; '' means the candidate
    # itself need only exist.
    $proof = if ($RequireProjects) { 'projects' } else { '' }
    $need  = if ($RequireProjects) { "a 'projects' subdirectory" } else { 'an existing directory' }

    $qualifies = {
        param([string]$Candidate, [string]$Proof)
        if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
        $probe = if ($Proof) { [System.IO.Path]::Combine($Candidate, $Proof) } else { $Candidate }
        return [System.IO.Directory]::Exists($probe)
    }

    # --- 1-3: authoritative sources — correct or fatal, never skipped ---
    foreach ($explicit in @(
            @{ Value = $ConfigRoot;            Source = '-ConfigRoot' },
            @{ Value = $env:CLAUDE_CONFIG_DIR; Source = '$env:CLAUDE_CONFIG_DIR' },
            @{ Value = $env:CLAUDE_HOME;       Source = '$env:CLAUDE_HOME' }))
    {
        if ([string]::IsNullOrWhiteSpace($explicit.Value)) { continue }
        # Normalized like the probed candidates, so every derived artifact path
        # looks the same regardless of which source won. CLAUDE_HOME is commonly
        # written with forward slashes.
        if (& $qualifies $explicit.Value $proof) { return [System.IO.Path]::GetFullPath($explicit.Value) }
        throw "$($explicit.Source) = '$($explicit.Value)' is not a usable Claude config root (expected $need)."
    }

    # --- 3: probe conventional locations ---
    $candidates = Get-ClaudeConfigRootCandidate

    foreach ($candidate in $candidates)
    {
        if (& $qualifies $candidate $proof) { return $candidate }
    }

    if ($candidates.Count -eq 0)
    {
        throw 'Cannot determine the user home directory; pass -ConfigRoot explicitly.'
    }

    if ($RequireProjects)
    {
        throw ("Cannot locate a Claude config root containing $need. " +
            "Pass -ConfigRoot or set `$env:CLAUDE_HOME. Probed:`n  " +
            ($candidates -join "`n  "))
    }

    return $candidates[0]
}


function Get-ClaudeProjectsRoot
{
    <#
    .SYNOPSIS
        Path to Claude Code's per-project transcript store.
    .DESCRIPTION
        `{configRoot}/projects`, with the root discovered by Get-ClaudeConfigRoot
        and required to actually contain the directory — so this either returns a
        path that exists or throws.
    .PARAMETER ConfigRoot
        Optional explicit config root. See Get-ClaudeConfigRoot.
    .OUTPUTS
        [string] absolute path to the projects root.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigRoot
    )

    $root = Get-ClaudeConfigRoot -ConfigRoot $ConfigRoot -RequireProjects
    return [System.IO.Path]::Combine($root, 'projects')
}

#endregion

#region --- New-JobWorkingDir ---

function Get-JobTimestamp
{
    <#
    .SYNOPSIS
        The single source of run-directory timestamps.
    .DESCRIPTION
        Every artifact directory this toolkit mints — job working dirs, batch
        roots, worker dispatch runs — takes its name stamp from here, so sibling
        directories under a shared root are directly comparable and sort in
        creation order.

        UTC, not local. Call sites were previously split between
        [datetime]::UtcNow and [DateTime]::Now, so two directories created in the
        same second could differ by the UTC offset and appear to be from
        different days. UTC also keeps names monotonic across a DST boundary,
        where local time repeats an hour and would collide.
    .PARAMETER At
        Instant to format. Defaults to now. Pass one explicit value to stamp a
        set of related directories with a single coordinated instant rather than
        letting each mint its own.
    .OUTPUTS
        [string] yyyyMMdd_HHmmss (UTC)
    #>
    [CmdletBinding()]
    param(
        [datetime]$At = [datetime]::UtcNow
    )

    return $At.ToUniversalTime().ToString('yyyyMMdd_HHmmss')
}


function New-JobWorkingDir
{
    <#
    .SYNOPSIS
        Mint a timestamped working directory for a pipeline run.
    .DESCRIPTION
        Creates $Root/$Prefix/yyyyMMdd_HHmmss/ and returns the full path.
        The root and prefix segments are parameterized so the convention
        can be changed later without touching internals. The stamp comes from
        Get-JobTimestamp (UTC) — see there for why.
    .PARAMETER Root
        Base directory. Defaults to `{claudeConfigRoot}/tmp`, discovered via
        Get-ClaudeConfigRoot.
    .PARAMETER Prefix
        Grouping segment under root (e.g. project name, session ID).
    #>
    [CmdletBinding()]
    param(
        [string]$Root,
        [Parameter(Mandatory)]
        [string]$Prefix
    )

    if (-not $Root)
    {
        # Discovered, not $env:CLAUDE_CONFIG_DIR: that variable is empty in most
        # agent shells, and Combine('', 'tmp') yields the relative path 'tmp',
        # which scattered run artifacts under the caller's current directory.
        $Root = [System.IO.Path]::Combine((Get-ClaudeConfigRoot), 'tmp')
    }

    $timestamp = Get-JobTimestamp
    $dirPath = [System.IO.Path]::Combine($Root, $Prefix, $timestamp)

    [void][System.IO.Directory]::CreateDirectory($dirPath)

    return $dirPath
}

#endregion

#region --- Expand-JsonArray ---

function Expand-JsonArray
{
    <#
    .SYNOPSIS
        Extract a nested array from a regular JSON file and write each element
        as a JSONL record, compatible with all jso-jackson read-side tools.

    .DESCRIPTION
        Navigates a dot-separated path inside a JSON file to locate an array,
        then writes each element as one compact JSON line to an output JSONL
        file. The output is fully compatible with Get-JsonlRecord, Read-Jsonl,
        Get-JsonlSchema, Get-JsonlValueDistribution, Find-JsonlByPath, and all
        other jso-jackson read-side tools.

        Parsing is done via System.Text.Json.JsonDocument — no PSCustomObject
        is allocated during navigation or write. Each element is serialized to
        compact (single-line) JSON via Utf8JsonWriter before being written, so
        the output is valid JSONL regardless of the source file's indentation.

        Use -BuildIndex to write a .jidx binary seek sidecar for O(1) random
        record access via Get-JsonlRecord -At.

    .PARAMETER Path
        Path to the source JSON file.

    .PARAMETER ArrayPath
        Dot-separated path to the target array within the JSON object.
        Use "." to target a root-level JSON array.
        Examples:  "items"   "data.records"   "result.pages"

    .PARAMETER OutputPath
        Path for the output JSONL file. Defaults to:
            <dir>/<stem>-<ArrayPath>.jsonl
        (dots in ArrayPath are replaced with hyphens) next to the source file.

    .PARAMETER BuildIndex
        Build a .jidx binary seek index after writing. Enables O(1) random
        access via Get-JsonlRecord -At N in subsequent calls.

    .OUTPUTS
        [pscustomobject] with:  OutputPath, IndexPath, RecordCount, SourcePath, ArrayPath

    .EXAMPLE
        Expand-JsonArray -Path .\report.json -ArrayPath "items" -BuildIndex
        # Writes report-items.jsonl + report-items.jsonl.jidx

    .EXAMPLE
        Expand-JsonArray -Path .\export.json -ArrayPath "result.pages" -OutputPath .\pages.jsonl

    .EXAMPLE
        # Expand a nested array, then run the full inspection chain
        $meta = Expand-JsonArray -Path .\export.json -ArrayPath "data.records" -BuildIndex
        Get-JsonlValueDistribution -Path $meta.OutputPath -JsonPath "type" -Top 20
        Get-JsonlSchema -Path $meta.OutputPath | Format-JsonlSchema | Format-Table -AutoSize
        Find-JsonlByPath -Path $meta.OutputPath -JsonPath "status" -Equals "error"
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ArrayPath,

        [string]$OutputPath,

        [switch]$BuildIndex
    )

    if (-not [System.IO.File]::Exists($Path))
    {
        throw "Expand-JsonArray: source file not found: $Path"
    }

    # Resolve default output path
    if (-not $OutputPath)
    {
        $dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $suffix = ($ArrayPath -replace '\.', '-').Trim('-')
        $OutputPath = [System.IO.Path]::Combine($dir, "$stem-$suffix.jsonl")
    }

    # Ensure output directory exists
    $outDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($OutputPath))
    [void][System.IO.Directory]::CreateDirectory($outDir)

    # Parse source JSON via JsonDocument — no PSCustomObject allocation
    # Cast to ReadOnlyMemory[byte] to resolve overload ambiguity in PowerShell.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $doc = [System.Text.Json.JsonDocument]::Parse([System.ReadOnlyMemory[byte]]$bytes)

    $count = 0
    try
    {
        # Navigate dot-path to the target element — reuse existing JsonlTraversal primitive.
        # "." is the sentinel for root-level array; any other path is delegated.
        $current = if ($ArrayPath -eq '.' -or [string]::IsNullOrWhiteSpace($ArrayPath))
        {
            $doc.RootElement
        }
        else
        {
            [JsonlTraversal]::GetElementRaw($doc.RootElement, $ArrayPath)
        }

        if ($current.ValueKind -eq [System.Text.Json.JsonValueKind]::Undefined)
        {
            throw "Expand-JsonArray: path '$ArrayPath' not found in '$Path'"
        }

        if ($current.ValueKind -ne [System.Text.Json.JsonValueKind]::Array)
        {
            throw "Expand-JsonArray: path '$ArrayPath' resolved to $($current.ValueKind), not an Array"
        }

        # Stream elements → compact JSONL via Utf8JsonWriter (no indentation)
        $memStream = [System.IO.MemoryStream]::new()
        $writerOpts = [System.Text.Json.JsonWriterOptions]::new()
        $writerOpts.Indented = $false

        $sw = [System.IO.StreamWriter]::new(
            $OutputPath,
            $false,    # overwrite
            [System.Text.Encoding]::UTF8
        )
        try
        {
            foreach ($element in $current.EnumerateArray())
            {
                $memStream.SetLength(0)
                $memStream.Position = 0
                $jw = [System.Text.Json.Utf8JsonWriter]::new($memStream, $writerOpts)
                $element.WriteTo($jw)
                $jw.Flush()
                $jw.Dispose()

                $line = [System.Text.Encoding]::UTF8.GetString(
                    $memStream.GetBuffer(), 0, [int]$memStream.Length
                )
                $sw.WriteLine($line)
                $count++
            }
        }
        finally
        {
            $sw.Dispose()
            $memStream.Dispose()
        }
    }
    finally
    {
        $doc.Dispose()
    }

    # Optionally build .jidx binary seek index
    $indexPath = $null
    if ($BuildIndex)
    {
        $idx = [JsonlIndex]::Build($OutputPath, "$OutputPath.jidx")
        $indexPath = $idx.IndexPath
    }

    return [pscustomobject]@{
        OutputPath  = $OutputPath
        IndexPath   = $indexPath
        RecordCount = $count
        SourcePath  = [System.IO.Path]::GetFullPath($Path)
        ArrayPath   = $ArrayPath
    }
}

#endregion
