<#
.LINK
    docs/rs-whitespace.md
#>
param(
    [Parameter(Position = 0)]
    [object]$Item,
    [Parameter(Position = 1)]
    [hashtable]$Config = @{}
)

#region Config
if ($Config.Count -eq 0 -or -not $Config.ContainsKey('Operations'))
{
    $Config = Resolve-ProcessorConfig -ProcessorName 'rs-whitespace' -CallerConfig $Config
}
$ops = @($Config['Operations'])
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }
#endregion

#region ContentKey
$bc = Resolve-BagContent -Item $Item
if ($null -eq $bc) { return $Item }

$t = $bc.Text
#endregion

#region Operations
$ran = @()
$skipped = @()

if ('lf' -in $ops)
{
    $ran += 'lf'
    $t = $t -replace "`r`n", "`n" -replace '[\r\u000B\u000C\u0085\u2028\u2029]', "`n"
}

if ('nfc' -in $ops)
{
    try
    {
        $t = $t.Normalize([System.Text.NormalizationForm]::FormC)
        $ran += 'nfc'
    }
    catch { $skipped += [pscustomobject]@{ Op = 'nfc'; Reason = 'InvalidUnicode' } }
}

if ('strip-zwsp' -in $ops)
{
    $ran += 'strip-zwsp'
    $t = $t -replace '\u200B', ''
}

if ('strip-wj' -in $ops)
{
    $ran += 'strip-wj'
    $t = $t -replace '\u2060', ''
}

if ('strip-zwnbsp' -in $ops)
{
    $ran += 'strip-zwnbsp'
    $t = $t -replace '\uFEFF', ''
}

if ('trim-trailing' -in $ops)
{
    $ran += 'trim-trailing'
    $lines = $t -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) { $lines[$i] = $lines[$i].TrimEnd() }
    $t = $lines -join "`n"
}

if ('trim-inner' -in $ops)
{
    $ran += 'trim-inner'
    $t = $t -replace '(?<=\S) {2,}(?=\S)', ' '
}

if ('max-blank-1' -in $ops)
{
    $ran += 'max-blank-1'
    $t = $t -replace "(`n){3,}", "`n`n"
}

if ('trim-doc' -in $ops)
{
    $ran += 'trim-doc'
    $t = $t -replace '^\n+', '' -replace '\n+$', ''
}

if ('ensure-final-lf' -in $ops)
{
    $ran += 'ensure-final-lf'
    if ($t.Length -gt 0 -and -not $t.EndsWith("`n")) { $t += "`n" }
}

if ('pad-breaks' -in $ops)
{
    $ran += 'pad-breaks'
    $t = $t -replace '(?<=\S)(?=\n)', ' ' -replace '(?<=\n)(?=\S)', ' '
}
#endregion

#region AuditReceipts
foreach ($requested in ($ops | Select-Object -Unique))
{
    if ($requested -in $ran) { continue }

    $alreadyRecorded = $false
    foreach ($s in $skipped) { if ($s.Op -eq $requested) { $alreadyRecorded = $true; break } }
    if (-not $alreadyRecorded) { $skipped += [pscustomobject]@{ Op = $requested; Reason = 'UnknownOp' } }
}
#endregion

#region Emit
$record = if ($includeMeta)
{
    $fields = [ordered]@{ Processor = 'rs-whitespace'; Operations = @($ran) }
    if ($skipped.Count) { $fields['Skipped'] = @($skipped) }
    [pscustomobject]$fields
}
else { $null }

return Copy-Bag -Item $Item -Resolved $bc -Content $t -Record $record
#endregion
