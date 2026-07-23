<#
.SYNOPSIS
    Language-agnostic text formatter (whitespace and encoding normalization).

.DESCRIPTION
    This file is loaded as a function body through SessionStateFunctionEntry.
    Keep it ISS-load-safe:
      - no #Requires directives
      - no outer function wrapper
      - param contract must be positional (Item, Config)

        Processor self-documentation only (no runtime enforcement in this file):
            - Intended Colonel IssPreset floor: Core
            - Supported RunMode usage: ApplyAll, KeyMatch
            - Required IssModules: none

.NOTES
        Host guidance for Colonel fluent setup:
            - Use SetIssPreset([IssPreset]::Core) or Full.
            - Bare is not recommended for this processor because it uses
                pipeline cmdlets such as ForEach-Object.
            - Config shape:
                    Operations: string[] (opt-in operation list)
                    IncludeMeta: bool (default true)

        Pipeline suitability per op:
            Op               TP-safe   RS opt-in   Notes
            lf               yes       yes         EOL -> LF; run first
            no-bom           yes       yes         Strip UTF-8 BOM
            nfc              yes       yes         Unicode NFC normalization
            strip-zwsp       yes       yes         Zero-width invisibles
            trim-trailing    yes       yes         Per-line trailing whitespace
            trim-inner       yes       yes         Inline multi-space collapse between words
            max-blank-2      yes       yes         Keep ≤2 blank lines; collapse 3+ blank lines to 2
            max-blank-1      caution   yes         Keep ≤1 blank line; collapse 2+ blank lines to 1; lossy for prose
            trim-doc         yes       yes         Strip leading/trailing blank lines from document
            eof-eot          no        yes         Append U+0004 sentinel; RS pipeline only
#>
# [CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [object]$Item,
    [Parameter(Position = 1)]
    [hashtable]$Config = @{}
)

$ops = if ($Config.ContainsKey('Operations')) { @($Config['Operations']) } else { @('lf', 'no-bom', 'nfc', 'strip-zwsp', 'trim-trailing', 'trim-inner', 'max-blank-2', 'trim-doc') }

$text = $null
$path = $null
$id = $null

if ($Item -is [string])
{
    $text = $Item
}
elseif ($Item -is [hashtable] -or $Item -is [pscustomobject])
{
    if ($null -ne $Item.PSObject.Properties['Text']) { $text = [string]$Item.Text }
    if ($null -ne $Item.PSObject.Properties['Path']) { $path = [string]$Item.Path }
    if ($null -ne $Item.PSObject.Properties['Id']) { $id = [string]$Item.Id }
}

if ([string]::IsNullOrEmpty($text))
{
    $text = ''
}

$t = $text

if ('lf' -in $ops)
{
    $t = $t -replace "`r`n", "`n" -replace "`r", "`n"
}

if ('no-bom' -in $ops)
{
    $t = $t -replace '^\uFEFF', ''
}

if ('nfc' -in $ops)
{
    try { $t = $t.Normalize([System.Text.NormalizationForm]::FormC) } catch {}
}

if ('strip-zwsp' -in $ops)
{
    $t = $t -replace '[\u200B\u200C\u200D\u2060\uFEFF]', ''
}

if ('trim-trailing' -in $ops)
{
    $t = ($t -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n"
}

if ('trim-inner' -in $ops)
{
    $t = $t -replace '(?<=\S) {2,}(?=\S)', ' '
}

if ('max-blank-2' -in $ops)
{
    $t = $t -replace "(`n){4,}", "`n`n`n"
}

if ('max-blank-1' -in $ops)
{
    $t = $t -replace "(`n){3,}", "`n`n"
}

if ('trim-doc' -in $ops)
{
    $t = $t -replace '^\n+', '' -replace '\n+$', ''
}

if ('eof-eot' -in $ops)
{
    $t = $t.TrimEnd("`r", "`n") + "`n`u{0004}"
}

$includeMeta = $true
if ($null -ne $Config['IncludeMeta']) { $includeMeta = [bool]$Config['IncludeMeta'] }

if (-not $includeMeta)
{
    return $t
}

return [pscustomobject]@{
    Id         = $id
    Path       = $path
    Text       = $t
    Operations = @($ops)
    Processor  = 'format'
}
