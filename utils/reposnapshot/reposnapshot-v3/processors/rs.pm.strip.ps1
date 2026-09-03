<#
.LINK
    docs/rs.pm.strip.md
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
    $Config = Resolve-ProcessorConfig -ProcessorName 'rs.pm.strip' -CallerConfig $Config
}
$ops = @($Config['Operations'])
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }
#endregion

#region ContentKey
$bc = Resolve-BagContent -Item $Item
if ($null -eq $bc) { return $Item }

$text = $bc.Text
#endregion

#region LineEndings
$text = $text -replace "`r`n", "`n" -replace "`r", "`n"
#endregion

#region BuildSpans
$spansToStrip = [System.Collections.Generic.List[pscustomobject]]::new()

$stripBlock  = 'block-comments'  -in $ops
$stripDoc    = 'doc-strings'     -in $ops
$stripCB     = 'comment-blocks'  -in $ops
$stripLine   = 'line-comments'   -in $ops
$stripInline = 'inline-comments' -in $ops
#endregion

#region MaskLiterals
# Length-preserving, newline-preserving lens: non-newline characters of strings,
# quote-like operators, regexes, heredoc bodies, and $# array-length sigils become
# U+0001 so comment regexes cannot see them. Spans computed on $view are offsets
# into $text. Unclosed quotes mask to EOL — safe under-strip.
$chars = $text.ToCharArray()
$fill = [char]0x01

# 1. Heredoc bodies: text starts on the next line and terminates at marker line
$rxHereDocDecl = [regex]::new('<<~?\s*(?:''([^''\n]+)''|"([^"\n]+)"|`([^`\n]+)`|\\?([a-zA-Z_]\w*))')
foreach ($m in $rxHereDocDecl.Matches($text))
{
    $marker = if ($m.Groups[1].Success) { $m.Groups[1].Value }
              elseif ($m.Groups[2].Success) { $m.Groups[2].Value }
              elseif ($m.Groups[3].Success) { $m.Groups[3].Value }
              else { $m.Groups[4].Value }
    if ([string]::IsNullOrEmpty($marker)) { continue }

    $nextNL = $text.IndexOf("`n", $m.Index)
    if ($nextNL -ge 0)
    {
        $bodyStart = $nextNL + 1
        $rxEnd = [regex]::new("(?m)^[ \t]*" + [regex]::Escape($marker) + "[ \t]*(?:\n|$)")
        $endMatch = $rxEnd.Match($text, $bodyStart)
        if ($endMatch.Success)
        {
            $bodyEnd = $endMatch.Index + $endMatch.Length
            for ($i = $bodyStart; $i -lt $bodyEnd; $i++)
            {
                if ($chars[$i] -ne "`n") { $chars[$i] = $fill }
            }
        }
    }
}

# 2. __DATA__ section: literal data, not comments
$rxData = [regex]::new('(?m)^__DATA__\s*$[\s\S]*')
$dataMatch = $rxData.Match($text)
if ($dataMatch.Success)
{
    $dEnd = $dataMatch.Index + $dataMatch.Length
    for ($i = $dataMatch.Index; $i -lt $dEnd; $i++)
    {
        if ($chars[$i] -ne "`n") { $chars[$i] = $fill }
    }
}

# 3. Literals regex: $# sigils, quote-like operators, regexes, strings
$rxLit = [regex]::new(
    '(?s)\$\#(?:\w+|\{[^\n\}]+\}|\$\w+|[^\s\n])?' +
    '|\b(?:qw|qq|qx|qr|q)\s*\((?:\\.|[^)\\])*\)' +
    '|\b(?:qw|qq|qx|qr|q)\s*\{(?:\\.|[^}\\])*\}' +
    '|\b(?:qw|qq|qx|qr|q)\s*\[(?:\\.|[^\]\\])*\]' +
    '|\b(?:qw|qq|qx|qr|q)\s*<(?:\\.|[^>\\])*>' +
    '|\b(?:qw|qq|qx|qr|q)\s*/(?:\\.|[^/\\\n])*/' +
    '|\b(?:qw|qq|qx|qr|q)\s*!(?:\\.|[^!\\\n])*!' +
    '|\b(?:qw|qq|qx|qr|q)\s*''(?:\\.|[^''\\\n])*''' +
    '|\b(?:qw|qq|qx|qr|q)\s*"(?:\\.|[^"\\\n])*"' +
    '|\bs/(?:\\.|[^/\\\n])*/(?:\\.|[^/\\\n])*/[msixpodualgcer]*' +
    '|\bs\{[^\n\}]*\}\s*\{[^\n\}]*\}[msixpodualgcer]*' +
    '|\bs\[[^\n\]]*\]\s*\[[^\n\]]*\][msixpodualgcer]*' +
    '|\bm/(?:\\.|[^/\\\n])*/[msixpodualgcer]*' +
    '|\bm\{[^\n\}]*\}[msixpodualgcer]*' +
    '|\b(?:tr|y)/(?:\\.|[^/\\\n])*/(?:\\.|[^/\\\n])*/[cds]*' +
    '|\b(?:tr|y)\{[^\n\}]*\}\s*\{[^\n\}]*\}[cds]*' +
    '|"(?:\\.|[^"\\\n])*"' +
    '|''(?:\\.|[^''\\\n])*''' +
    '|`(?:\\.|[^`\\\n])*`' +
    '|(?<=[=(,:[!&|?+*%~^<>;{}\s-]|^)/(?!/|\*)(?:\\.|[^/\r\n\\])+/[msixpodualgcer]*' +
    '|"(?:\\.|[^"\\\n])*' +
    '|''(?:\\.|[^''\\\n])*' +
    '|`(?:\\.|[^`\\\n])*',
    'None'
)

foreach ($m in $rxLit.Matches($text))
{
    $end = $m.Index + $m.Length
    for ($i = $m.Index; $i -lt $end; $i++)
    {
        if ($chars[$i] -ne "`n") { $chars[$i] = $fill }
    }
}
$view = [string]::new($chars)
#endregion

#region POD Documentation
# In Perl, POD (=head1 ... =cut) represents both documentation blocks and
# multi-line docstrings. 'doc-strings' and 'block-comments' both strip POD blocks.
if ($stripDoc -or $stripBlock)
{
    $rxPod = [regex]::new('(?sm)^=[a-zA-Z]\w*.*?(?:^=cut[^\n]*(?:\n|$)|(?!\n)\Z)')
    foreach ($m in $rxPod.Matches($view))
    {
        $spansToStrip.Add([pscustomobject]@{ Start = $m.Index; End = $m.Index + $m.Length })
    }
}
#endregion

#region StandaloneLines
if ($stripCB -or $stripLine)
{
    $rxLine = [regex]::new('(?m)^([^\S\n]*)#[^\n]*(\n)?', 'None')
    $standaloneMatches = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($m in $rxLine.Matches($view))
    {
        $s = $m.Index
        $lineNum = ($view.Substring(0, $s) -split "`n").Count
        $lineText = $m.Value -replace '\n$', ''

        # Shebang on line 1 is FrontMatter — never stripped
        if ($s -eq 0 -and $lineText.StartsWith('#!')) { continue }

        $hashIdx = $m.Index + $m.Groups[1].Length
        $before = $view.Substring($m.Index, $hashIdx - $m.Index)
        if ($before -match '\S') { continue }

        $standaloneMatches.Add([pscustomobject]@{
            LineNum = $lineNum
            Start   = $m.Index
            End     = $m.Index + $m.Length
        })
    }

    $runStartI = -1
    $runEndI = -1
    $cbFlags = @($false) * $standaloneMatches.Count

    for ($i = 0; $i -lt $standaloneMatches.Count; $i++)
    {
        $cur = $standaloneMatches[$i]
        if ($runStartI -eq -1)
        {
            $runStartI = $i; $runEndI = $i
        }
        elseif ($cur.LineNum -eq $standaloneMatches[$runEndI].LineNum + 1)
        {
            $runEndI = $i
        }
        else
        {
            if ($runEndI -gt $runStartI) { for ($j = $runStartI; $j -le $runEndI; $j++) { $cbFlags[$j] = $true } }
            $runStartI = $i; $runEndI = $i
        }
    }
    if ($runStartI -ne -1 -and $runEndI -gt $runStartI) { for ($j = $runStartI; $j -le $runEndI; $j++) { $cbFlags[$j] = $true } }

    for ($i = 0; $i -lt $standaloneMatches.Count; $i++)
    {
        $shouldStrip = if ($cbFlags[$i]) { $stripCB } else { $stripLine }
        if (-not $shouldStrip) { continue }
        $sm = $standaloneMatches[$i]
        $ls2 = $sm.Start
        while ($ls2 -gt 0 -and ($view[$ls2 - 1] -eq ' ' -or $view[$ls2 - 1] -eq "`t")) { $ls2-- }
        $s2 = if ($ls2 -eq 0 -or $view[$ls2 - 1] -eq "`n") { $ls2 } else { $sm.Start }
        $spansToStrip.Add([pscustomobject]@{ Start = $s2; End = $sm.End })
    }
}
#endregion

#region InlineComments
if ($stripInline)
{
    $rxInline = [regex]::new('[ \t]*#[^\n]*', 'None')
    foreach ($m in $rxInline.Matches($view))
    {
        $lineStart = $view.LastIndexOf("`n", $m.Index)
        $lineStart = if ($lineStart -eq -1) { 0 } else { $lineStart + 1 }
        $before = $view.Substring($lineStart, $m.Index - $lineStart)
        if ($before -notmatch '\S') { continue }
        $spansToStrip.Add([pscustomobject]@{ Start = $m.Index; End = $m.Index + $m.Length })
    }
}
#endregion

#region MergeSpans
$merged = [System.Collections.Generic.List[pscustomobject]]::new()

if ($spansToStrip.Count -gt 0)
{
    $spansToStrip.Sort([System.Comparison[object]] { param($a, $b) $a.Start.CompareTo($b.Start) })
    $sorted = $spansToStrip
    $cur = [pscustomobject]@{ Start = $sorted[0].Start; End = $sorted[0].End }

    for ($i = 1; $i -lt $sorted.Count; $i++)
    {
        $nxt = $sorted[$i]
        if ($nxt.Start -le $cur.End)
        {
            if ($nxt.End -gt $cur.End) { $cur = [pscustomobject]@{ Start = $cur.Start; End = $nxt.End } }
        }
        else
        {
            $merged.Add($cur)
            $cur = [pscustomobject]@{ Start = $nxt.Start; End = $nxt.End }
        }
    }
    $merged.Add($cur)
}
#endregion

#region ReconstructText
$sb = [System.Text.StringBuilder]::new($text.Length)
$pos = 0

foreach ($span in $merged)
{
    if ($span.Start -gt $pos)
    {
        $null = $sb.Append($text.Substring($pos, $span.Start - $pos))
    }
    $pos = $span.End
}
if ($pos -lt $text.Length)
{
    $null = $sb.Append($text.Substring($pos))
}

$stripped = $sb.ToString()
#endregion

#region Emit
$record = if ($includeMeta)
{
    [pscustomobject]@{
        Processor      = (Resolve-ProcessorLabel -Implementation 'rs.pm.strip' -Config $Config)
        Implementation = 'rs.pm.strip'
        Operations     = @($ops)
    }
}
else { $null }
return Copy-Bag -Item $Item -Resolved $bc -Content $stripped -Record $record
#endregion
