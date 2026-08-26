<#
.LINK
    docs/tp-perplexity.md
#>
param(
    [Parameter(Position = 0)]
    [object]$Item,

    [Parameter(Position = 1)]
    [hashtable]$Config = @{}
)

#region Config
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }
$stripInlineCites = if ($null -ne $Config['StripInlineCites']) { [bool]$Config['StripInlineCites'] } else { $false }
#endregion

#region ItemUnpacking
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
    elseif ($null -ne $Item.PSObject.Properties['Content']) { $text = [string]$Item.Content }
    if ($null -ne $Item.PSObject.Properties['Path']) { $path = [string]$Item.Path }
    if ($null -ne $Item.PSObject.Properties['Id']) { $id = [string]$Item.Id }
}

if ([string]::IsNullOrEmpty($text))
{
    if (-not $includeMeta) { return @() }
    return [pscustomobject]@{
        Id        = $id
        Path      = $path
        Exchanges = @()
        Processor = 'threadparser-perplexity'
    }
}
#endregion

#region NormalizationAndRepair
$text = $text -replace "`r`n", "`n" -replace "`r", "`n"

# Defensive repair: scrub trailing `---` lines and surrounding whitespace
$text = $text.TrimEnd()
while ($text -match '\n[ \t]*-{3,}[ \t]*$')
{
    $text = ($text -replace '\n[ \t]*-{3,}[ \t]*$', '').TrimEnd()
}
#endregion

#region Helper_MaskByRegex
$SENT_OPEN = [char]0xE000
$SENT_CLOSE = [char]0xE001
$RX_NB = [System.Text.RegularExpressions.RegexOptions]::NonBacktracking
$RX_NB_M = $RX_NB -bor [System.Text.RegularExpressions.RegexOptions]::Multiline

function _MaskByRegex
{
    param(
        [string]$InputText,
        [System.Text.RegularExpressions.Regex]$Rx,
        [string]$Tag,
        [System.Collections.Generic.List[object]]$Store
    )

    $matches = $Rx.Matches($InputText)
    if ($matches.Count -eq 0) { return $InputText }

    $sb = [System.Text.StringBuilder]::new($InputText.Length)
    $pos = 0
    foreach ($m in $matches)
    {
        if ($m.Index -gt $pos) { [void]$sb.Append($InputText.Substring($pos, $m.Index - $pos)) }
        $i = $Store.Count
        $Store.Add($m.Value)
        [void]$sb.Append("$SENT_OPEN$Tag`:$i$SENT_CLOSE")
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $InputText.Length) { [void]$sb.Append($InputText.Substring($pos)) }
    return $sb.ToString()
}
#endregion

#region Stage1_StripHtml
$text = [regex]::Replace(
    $text,
    '(?is)<span\s+style\s*=\s*"display:\s*none[^"]*"[^>]*>.*?</span>',
    ''
)
$text = [regex]::Replace(
    $text,
    '(?is)<div\s+align\s*=\s*"center"[^>]*>.*?</div>',
    ''
)
#endregion

#region Stage2_MaskCodeBlocks
$codeBlocks = [System.Collections.Generic.List[object]]::new()
$rxCode = [regex]::new(
    '(?ms)^[ \t]*`{3,}[^\n]*\n.*?\n[ \t]*`{3,}[ \t]*$',
    $RX_NB_M
)
$text = _MaskByRegex -InputText $text -Rx $rxCode -Tag 'CODE' -Store $codeBlocks
#endregion

#region Stage3_MaskCitationFooters
$footerBlocks = [System.Collections.Generic.List[object]]::new()
$rxFooter = [regex]::new(
    '(?m)(?:^\[\^[\w]+\]:[^\n]*\n?)+',
    $RX_NB_M
)
$rxFooterEntry = [regex]::new('(?m)^\[\^([\w]+)\]:\s*(.+?)\s*$')

$footerMatches = $rxFooter.Matches($text)
if ($footerMatches.Count -gt 0)
{
    $sb = [System.Text.StringBuilder]::new($text.Length)
    $pos = 0
    foreach ($m in $footerMatches)
    {
        if ($m.Index -gt $pos) { [void]$sb.Append($text.Substring($pos, $m.Index - $pos)) }

        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($em in $rxFooterEntry.Matches($m.Value))
        {
            $entries.Add([pscustomobject]@{
                    Id      = $em.Groups[1].Value
                    Content = $em.Groups[2].Value
                })
        }
        $i = $footerBlocks.Count
        $footerBlocks.Add($entries.ToArray())
        [void]$sb.Append("$SENT_OPEN`FOOTER:$i$SENT_CLOSE")
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $text.Length) { [void]$sb.Append($text.Substring($pos)) }
    $text = $sb.ToString()
}
#endregion

#region Stage4_MaskInlineCites
$inlineCites = [System.Collections.Generic.List[object]]::new()
$rxInlineCite = [regex]::new(
    '\[\^[\w]+\](?:\s*(?:and\s+)?\[\^[\w]+\])*',
    [System.Text.RegularExpressions.RegexOptions]::None
)
$text = _MaskByRegex -InputText $text -Rx $rxInlineCite -Tag 'CITE' -Store $inlineCites
#endregion

#region Stage5_SplitTerminus
$rxFooterSent = [regex]::new("$SENT_OPEN`FOOTER:\d+$SENT_CLOSE")
$rxHr = [regex]::new('(?m)^[ \t]*-{3,}[ \t]*$')
$rxNextH1 = [regex]::new('\A[\r\n \t]*#[ \t]+\S')

$splitSpans = [System.Collections.Generic.List[object]]::new()
foreach ($m in $rxHr.Matches($text))
{
    $isTerminus = $false

    # Rule 1: preceding context is a footer-block sentinel
    $back = $m.Index - 1
    while ($back -ge 0)
    {
        $ch = $text[$back]
        if ($ch -ne ' ' -and $ch -ne "`t" -and $ch -ne "`n" -and $ch -ne "`r") { break }
        $back--
    }
    if ($back -ge 0)
    {
        $scanStart = [math]::Max(0, $back - 32)
        $window = $text.Substring($scanStart, $back - $scanStart + 1)
        if ($rxFooterSent.IsMatch($window)) { $isTerminus = $true }
    }

    # Rule 2: next non-whitespace content is an H1 line
    if (-not $isTerminus)
    {
        $forwardStart = $m.Index + $m.Length
        if ($forwardStart -lt $text.Length)
        {
            $forward = $text.Substring($forwardStart, [math]::Min(256, $text.Length - $forwardStart))
            if ($rxNextH1.IsMatch($forward)) { $isTerminus = $true }
        }
    }

    if ($isTerminus)
    {
        $splitSpans.Add([pscustomobject]@{
                Start = $m.Index
                End   = $m.Index + $m.Length
            })
    }
}

$chunks = [System.Collections.Generic.List[string]]::new()
$prev = 0
foreach ($s in $splitSpans)
{
    if ($s.Start -gt $prev)
    {
        $chunks.Add($text.Substring($prev, $s.Start - $prev))
    }
    $prev = $s.End
}
if ($prev -lt $text.Length)
{
    $chunks.Add($text.Substring($prev))
}

$kept = [System.Collections.Generic.List[string]]::new()
foreach ($c in $chunks) { if (-not [string]::IsNullOrWhiteSpace($c)) { $kept.Add($c) } }
$chunks = @($kept)
#endregion

#region Stage6_7_ChunkExtractAndRestore
$rxH1 = [regex]::new('(?m)^[ \t]*#[ \t]+(.*?)[ \t]*$')
$rxCodeSent = [regex]::new("$SENT_OPEN`CODE:(\d+)$SENT_CLOSE")
$rxCiteSent = [regex]::new("$SENT_OPEN`CITE:(\d+)$SENT_CLOSE")

$exchanges = [System.Collections.Generic.List[object]]::new()
$exchangeIdx = 0

foreach ($chunk in $chunks)
{
    $body = $chunk.Trim()
    if ([string]::IsNullOrEmpty($body)) { continue }

    # Pull citations off the footer sentinel (if present)
    $citations = @()
    $fm = $rxFooterSent.Match($body)
    if ($fm.Success)
    {
        $idxMatch = [regex]::Match($fm.Value, 'FOOTER:(\d+)')
        if ($idxMatch.Success)
        {
            $bi = [int]$idxMatch.Groups[1].Value
            if ($bi -ge 0 -and $bi -lt $footerBlocks.Count)
            {
                $citations = $footerBlocks[$bi]
            }
        }
        $body = $rxFooterSent.Replace($body, '').TrimEnd()
    }

    # Locate first H1 — prompt anchor
    $h1Match = $rxH1.Match($body)
    $prompt = ''
    $reply = ''

    if ($h1Match.Success)
    {
        $prompt = $h1Match.Groups[1].Value
        $afterH1 = $body.Substring($h1Match.Index + $h1Match.Length)
        $reply = ($afterH1 -replace '^[\r\n \t]+', '').TrimEnd()
    }
    else
    {
        $reply = $body
    }

    # Restore code-block sentinels
    if ($prompt -and $rxCodeSent.IsMatch($prompt))
    {
        $sb = [System.Text.StringBuilder]::new($prompt.Length)
        $pos = 0
        foreach ($m in $rxCodeSent.Matches($prompt))
        {
            if ($m.Index -gt $pos) { [void]$sb.Append($prompt.Substring($pos, $m.Index - $pos)) }
            [void]$sb.Append([string]$codeBlocks[[int]$m.Groups[1].Value])
            $pos = $m.Index + $m.Length
        }
        if ($pos -lt $prompt.Length) { [void]$sb.Append($prompt.Substring($pos)) }
        $prompt = $sb.ToString()
    }
    if ($reply -and $rxCodeSent.IsMatch($reply))
    {
        $sb = [System.Text.StringBuilder]::new($reply.Length)
        $pos = 0
        foreach ($m in $rxCodeSent.Matches($reply))
        {
            if ($m.Index -gt $pos) { [void]$sb.Append($reply.Substring($pos, $m.Index - $pos)) }
            [void]$sb.Append([string]$codeBlocks[[int]$m.Groups[1].Value])
            $pos = $m.Index + $m.Length
        }
        if ($pos -lt $reply.Length) { [void]$sb.Append($reply.Substring($pos)) }
        $reply = $sb.ToString()
    }

    # Restore inline cite clusters
    if ($stripInlineCites)
    {
        if ($prompt) { $prompt = $rxCiteSent.Replace($prompt, '') }
        if ($reply) { $reply = $rxCiteSent.Replace($reply, '') }
    }
    else
    {
        if ($prompt -and $rxCiteSent.IsMatch($prompt))
        {
            $sb = [System.Text.StringBuilder]::new($prompt.Length)
            $pos = 0
            foreach ($m in $rxCiteSent.Matches($prompt))
            {
                if ($m.Index -gt $pos) { [void]$sb.Append($prompt.Substring($pos, $m.Index - $pos)) }
                [void]$sb.Append([string]$inlineCites[[int]$m.Groups[1].Value])
                $pos = $m.Index + $m.Length
            }
            if ($pos -lt $prompt.Length) { [void]$sb.Append($prompt.Substring($pos)) }
            $prompt = $sb.ToString()
        }
        if ($reply -and $rxCiteSent.IsMatch($reply))
        {
            $sb = [System.Text.StringBuilder]::new($reply.Length)
            $pos = 0
            foreach ($m in $rxCiteSent.Matches($reply))
            {
                if ($m.Index -gt $pos) { [void]$sb.Append($reply.Substring($pos, $m.Index - $pos)) }
                [void]$sb.Append([string]$inlineCites[[int]$m.Groups[1].Value])
                $pos = $m.Index + $m.Length
            }
            if ($pos -lt $reply.Length) { [void]$sb.Append($reply.Substring($pos)) }
            $reply = $sb.ToString()
        }
    }

    $exchanges.Add([pscustomobject]@{
            Index     = $exchangeIdx
            Prompt    = $prompt
            Reply     = $reply
            Citations = $citations
        })
    $exchangeIdx++
}
#endregion

#region Emit
if (-not $includeMeta) { return $exchanges.ToArray() }

return [pscustomobject]@{
    Id        = $id
    Path      = $path
    Exchanges = $exchanges.ToArray()
    Processor = 'threadparser-perplexity'
}
#endregion
