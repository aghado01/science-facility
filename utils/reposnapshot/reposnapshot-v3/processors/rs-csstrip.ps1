<#
.LINK
    docs/rs-csstrip.md
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
    $Config = Resolve-ProcessorConfig -ProcessorName 'rs-csstrip' -CallerConfig $Config
}
$ops = @($Config['Operations'])
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }
#endregion

#region ContentKey
# Read Content (descriptor contract) else Text (tp-era); write back the same key.
$bc = Resolve-BagContent -Item $Item
if ($null -eq $bc) { return $Item }

$text = $bc.Text
#endregion

#region LineEndings
$text = $text -replace "`r`n", "`n" -replace "`r", "`n"
#endregion

#region BuildSpans
$spansToStrip = [System.Collections.Generic.List[pscustomobject]]::new()

$stripBlock    = 'block-comments'    -in $ops
$stripInterior = 'interior-comments' -in $ops
$stripDoc      = 'doc-strings'       -in $ops
$stripCB       = 'comment-blocks'    -in $ops
$stripLine     = 'line-comments'     -in $ops
$stripInline   = 'inline-comments'   -in $ops
#endregion

#region BlockComments
# /* ... */ — classifies matches as standalone or inline-block
if ($stripBlock -or $stripInterior)
{
    $rx = [regex]::new('(?s)/\*.*?\*/', 'None')
    foreach ($m in $rx.Matches($text))
    {
        $s = $m.Index
        $e = $m.Index + $m.Length

        # Code-before check: walk back from /* over whitespace
        $ls = $s
        while ($ls -gt 0 -and ($text[$ls - 1] -eq ' ' -or $text[$ls - 1] -eq "`t")) { $ls-- }
        $standaloneStart = ($ls -eq 0 -or $text[$ls - 1] -eq "`n")

        # Code-after check: scan from */ to end of line
        $lineEnd = $text.IndexOf("`n", $e)
        if ($lineEnd -eq -1) { $lineEnd = $text.Length }
        $standaloneEnd = ($text.Substring($e, $lineEnd - $e) -notmatch '\S')

        if ($standaloneStart -and $standaloneEnd)
        {
            if (-not $stripBlock) { continue }
            # Expand span: consume leading indent and trailing newline
            $s = $ls
            if ($e -lt $text.Length -and $text[$e] -eq "`n") { $e++ }
        }
        else
        {
            if (-not $stripInterior) { continue }
            # Strip only the /* */ token; surrounding code is kept intact
        }

        $spansToStrip.Add([pscustomobject]@{ Start = $s; End = $e })
    }
}
#endregion

#region DocStrings
# /// (triple-slash XML doc comments)
if ($stripDoc)
{
    $rxDoc = [regex]::new('(?m)^([^\S\n]*)///[^\n]*(\n)?', 'None')
    foreach ($m in $rxDoc.Matches($text))
    {
        $spansToStrip.Add([pscustomobject]@{ Start = $m.Index; End = $m.Index + $m.Length })
    }
}
#endregion

#region StandaloneLines
# Standalone // lines — collect, then classify into LineComment / CommentBlock
if ($stripCB -or $stripLine)
{
    $rxLine = [regex]::new('(?m)^([^\S\n]*)//(?!/)[^\n]*(\n)?', 'None')

    $standaloneMatches = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($m in $rxLine.Matches($text))
    {
        # Verify no code precedes // on this line
        $slashIdx = $m.Index + $m.Groups[1].Length
        $before = $text.Substring($m.Index, $slashIdx - $m.Index)
        if ($before -match '\S') { continue }   # code before // → InlineComment

        $lineNum = ($text.Substring(0, $m.Index) -split "`n").Count

        $standaloneMatches.Add([pscustomobject]@{
                LineNum = $lineNum
                Start   = $m.Index
                End     = $m.Index + $m.Length
            })
    }

    # Reclassify runs of 2+ consecutive lines as CommentBlock
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
        while ($ls2 -gt 0 -and ($text[$ls2 - 1] -eq ' ' -or $text[$ls2 - 1] -eq "`t")) { $ls2-- }
        $s2 = if ($ls2 -eq 0 -or $text[$ls2 - 1] -eq "`n") { $ls2 } else { $sm.Start }
        $spansToStrip.Add([pscustomobject]@{ Start = $s2; End = $sm.End })
    }
}
#endregion

#region InlineComments
# // after code on the same line
if ($stripInline)
{
    $rxInline = [regex]::new('[ \t]*//(?!/)[^\n]*', 'None')
    foreach ($m in $rxInline.Matches($text))
    {
        $lineStart = $text.LastIndexOf("`n", $m.Index)
        $lineStart = if ($lineStart -eq -1) { 0 } else { $lineStart + 1 }
        $before = $text.Substring($lineStart, $m.Index - $lineStart)
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
# Copy-on-mutate return — harmonized content-mutator contract (6d)
$record = if ($includeMeta) { [pscustomobject]@{ Processor = 'rs-csstrip'; Operations = @($ops) } } else { $null }
return Copy-Bag -Item $Item -Resolved $bc -Content $stripped -Record $record
#endregion
