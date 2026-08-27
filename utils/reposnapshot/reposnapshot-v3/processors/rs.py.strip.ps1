<#
.LINK
    docs/rs.py.strip.md
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
    $Config = Resolve-ProcessorConfig -ProcessorName 'rs.py.strip' -CallerConfig $Config
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

$stripBlock  = 'block-comments' -in $ops
$stripDoc    = 'doc-strings'    -in $ops
$stripCB     = 'comment-blocks' -in $ops
$stripLine   = 'line-comments'  -in $ops
$stripInline = 'inline-comments' -in $ops
#endregion

#region MaskLiterals
# Prefixes: r/u/f/b and the two-char combos. Closed forms first, then unclosed
# triples to EOF and unclosed singles to EOL.
$dq3 = '"""'
$sq3 = "'''"
$rxLit = [regex]::new(
    ('(?s)(?:[rR][fFbB]?|[fF][rR]?|[bB][rR]?|[uU])?{0}[\s\S]*?{0}|(?:[rR][fFbB]?|[fF][rR]?|[bB][rR]?|[uU])?{1}[\s\S]*?{1}|(?:[rR][fFbB]?|[fF][rR]?|[bB][rR]?|[uU])?"(?:\\.|[^"\\\n])*"|(?:[rR][fFbB]?|[fF][rR]?|[bB][rR]?|[uU])?''(?:\\.|[^''\\\n])*''|(?:[rR][fFbB]?|[fF][rR]?|[bB][rR]?|[uU])?{0}[\s\S]*|(?:[rR][fFbB]?|[fF][rR]?|[bB][rR]?|[uU])?{1}[\s\S]*|(?:[rR][fFbB]?|[fF][rR]?|[bB][rR]?|[uU])?"(?:\\.|[^"\\\n])*|(?:[rR][fFbB]?|[fF][rR]?|[bB][rR]?|[uU])?''(?:\\.|[^''\\\n])*' -f $dq3, $sq3),
    'None')

$litMatches = @($rxLit.Matches($text))
$chars = $text.ToCharArray()
$fill = [char]0x01
foreach ($m in $litMatches)
{
    $end = $m.Index + $m.Length
    for ($i = $m.Index; $i -lt $end; $i++)
    {
        if ($chars[$i] -ne "`n") { $chars[$i] = $fill }
    }
}
$view = [string]::new($chars)
#endregion

#region DocStrings
# Statement-position triples (only indent before on the line) are DocString.
# block-comments is an alias so the default op list is not a dead letter.
# Classification uses $text (original) so we see the quotes; interiors are
# already masked in $view for the later # pass.
if ($stripDoc -or $stripBlock)
{
    foreach ($m in $litMatches)
    {
        $v = $m.Value
        $bare = $v -replace '^[rRuUfFbB]{1,2}', ''
        $isTriple = $bare.StartsWith($dq3) -or $bare.StartsWith($sq3)
        if (-not $isTriple) { continue }

        $closed = ($bare.StartsWith($dq3) -and $bare.EndsWith($dq3) -and $bare.Length -ge 6) -or
                  ($bare.StartsWith($sq3) -and $bare.EndsWith($sq3) -and $bare.Length -ge 6)
        if (-not $closed) { continue }

        $s = $m.Index
        $e = $m.Index + $m.Length
        $ls = $s
        while ($ls -gt 0 -and ($text[$ls - 1] -eq ' ' -or $text[$ls - 1] -eq "`t")) { $ls-- }
        if (-not ($ls -eq 0 -or $text[$ls - 1] -eq "`n")) { continue }

        $s = $ls
        $lineEnd = $text.IndexOf("`n", $e)
        if ($lineEnd -eq -1) { $lineEnd = $text.Length }
        if ($text.Substring($e, $lineEnd - $e) -notmatch '\S')
        {
            if ($e -lt $text.Length -and $text[$e] -eq "`n") { $e++ }
        }
        $spansToStrip.Add([pscustomobject]@{ Start = $s; End = $e })
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

        if ($s -eq 0 -and $lineText.StartsWith('#!')) { continue }
        if ($lineNum -le 2 -and $lineText -match '^[ \t]*#[^\n]*coding[:=][ \t]*[-_.a-zA-Z0-9]+') { continue }

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
        Processor      = (Resolve-ProcessorLabel -Implementation 'rs.py.strip' -Config $Config)
        Implementation = 'rs.py.strip'
        Operations     = @($ops)
    }
}
else { $null }
return Copy-Bag -Item $Item -Resolved $bc -Content $stripped -Record $record
#endregion
