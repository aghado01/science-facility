# See [rs-indent.md](docs/rs-indent.md) for docstring
param(
    [Parameter(Position = 0)]
    [object]$Item,

    [Parameter(Position = 1)]
    [hashtable]$Config = @{}
)

#region Config
$ops = @($Config['Operations'])
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }
$targetUnit = if ($null -ne $Config['TargetUnit'] -and [int]$Config['TargetUnit'] -gt 0) { [int]$Config['TargetUnit'] } else { 2 }
#endregion

#region ContentKey
$bc = Resolve-BagContent -Item $Item
if ($null -eq $bc) { return $Item }

$text = $bc.Text
#endregion

#region SkipList
# RelativePath (descriptor) else Path (tp-era)
$path = $null
if ('RelativePath' -in $bc.Keys) { $path = [string]$Item.RelativePath }
elseif ('Path' -in $bc.Keys) { $path = [string]$Item.Path }

$ext = if ($path) { [IO.Path]::GetExtension($path).ToLowerInvariant() } else { '' }
$skipExts = @('.md', '.txt', '.rst', '.html', '.htm', '.xml', '.json', '.yaml', '.yml', '.toml', '.csv')
$skipped = $ext -in $skipExts
#endregion

#region GatesAndLineSplit
$doStripCommon = (-not $skipped) -and ('strip-common' -in $ops)
$doDetab       = (-not $skipped) -and ('detab' -in $ops -or 'min-indent-2' -in $ops -or 'tabify' -in $ops)
$doMinIndent   = (-not $skipped) -and ('min-indent-2' -in $ops)
$doTabify      = (-not $skipped) -and ('tabify' -in $ops)

# Split physical lines while preserving original terminator bytes for reassembly.
$termPattern = '\r\n|\r|\n|\u0085|\u2028|\u2029|\x0B|\x0C'
$parts = [regex]::Split($text, "($termPattern)")
$lines = [string[]]::new(($parts.Count + 1) / 2)
$terms = [string[]]::new($lines.Count - 1)
for ($i = 0; $i -lt $parts.Count; $i++)
{
    if ($i % 2 -eq 0) { $lines[$i / 2] = $parts[$i] } else { $terms[($i - 1) / 2] = $parts[$i] }
}
$depths = [int[]]::new($lines.Count)
#endregion

#region Stage1_StripCommon
# Subtract minimum leading-space depth across all non-blank lines.
if ($doStripCommon)
{
    $spaceLeads = [System.Collections.Generic.List[int]]::new()
    foreach ($line in $lines)
    {
        if ($line -match '\S')
        {
            $m = [regex]::Match($line, '^ +')
            $depth = if ($m.Success) { $m.Length } else { 0 }
            $spaceLeads.Add($depth)
        }
    }

    if ($spaceLeads.Count -gt 0)
    {
        $common = $spaceLeads[0]
        foreach ($d in $spaceLeads) { if ($d -lt $common) { $common = $d } }
        if ($common -gt 0)
        {
            for ($i = 0; $i -lt $lines.Count; $i++)
            {
                if ($lines[$i] -match '\S')
                {
                    $m = [regex]::Match($lines[$i], '^ +')
                    $leadSpaces = if ($m.Success) { $m.Length } else { 0 }
                    $strip = [math]::Min($common, $leadSpaces)
                    if ($strip -gt 0) { $lines[$i] = $lines[$i].Substring($strip) }
                }
            }
        }
    }
}
#endregion

#region Stage2_Detab
# Extract leading \s+ per line, expand tabs to TargetUnit spaces, accumulate space-depth.
if ($doDetab)
{
    for ($i = 0; $i -lt $lines.Count; $i++)
    {
        $seg = [regex]::Match($lines[$i], '^\s+').Value
        if (-not $seg) { $depths[$i] = 0; continue }

        if ($seg -match '\t')
        {
            $expanded = $seg -replace '\t', (' ' * $targetUnit)
            $lines[$i] = $expanded + $lines[$i].Substring($seg.Length)
            $seg = $expanded
        }

        $depths[$i] = $seg.Length
    }
}
#endregion

#region Stage3_MinIndent2
# GCD-infer file's current indent unit and rescale depths uniformly to TargetUnit.
if ($doMinIndent)
{
    $nonZero = [System.Collections.Generic.List[int]]::new()
    foreach ($d in $depths) { if ($d -gt 0) { $nonZero.Add($d) } }
    if ($nonZero.Count -gt 0)
    {
        $gcd = $nonZero[0]
        for ($i = 1; $i -lt $nonZero.Count; $i++)
        {
            $a = $gcd; $b = $nonZero[$i]
            while ($b -ne 0) { $tmp = $a % $b; $a = $b; $b = $tmp }
            $gcd = $a
        }

        if ($gcd -gt 0 -and $gcd -ne $targetUnit)
        {
            for ($i = 0; $i -lt $lines.Count; $i++)
            {
                if ($depths[$i] -gt 0)
                {
                    $newDepth = [int]($depths[$i] * $targetUnit / $gcd)
                    $rest = $lines[$i].Substring($depths[$i])
                    $lines[$i] = (' ' * $newDepth) + $rest
                    $depths[$i] = $newDepth
                }
            }
        }
    }
}
#endregion

#region Stage4_Tabify
# Convert leading space runs to tabs at TargetUnit width.
if ($doTabify)
{
    for ($i = 0; $i -lt $lines.Count; $i++)
    {
        if ($depths[$i] -gt 0)
        {
            $tabs = [math]::Floor($depths[$i] / $targetUnit)
            $remainder = $depths[$i] % $targetUnit
            $rest = $lines[$i].Substring($depths[$i])
            $lines[$i] = ("`t" * $tabs) + (' ' * $remainder) + $rest
        }
    }
}
#endregion

#region Reassembly
# Reassemble with each line's original terminator preserved verbatim.
$sb = [System.Text.StringBuilder]::new()
for ($i = 0; $i -lt $lines.Count; $i++)
{
    [void]$sb.Append($lines[$i])
    if ($i -lt $terms.Count) { [void]$sb.Append($terms[$i]) }
}
$t = $sb.ToString()
#endregion

#region Emit
# Copy-on-mutate return — harmonized content-mutator contract (6d)
$record = if ($includeMeta)
{
    [pscustomobject]@{ Processor = 'rs-indent'; Operations = @($ops); Skipped = $skipped }
}
else { $null }

return Copy-Bag -Item $Item -Resolved $bc -Content $t -Record $record
#endregion
