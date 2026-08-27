<#
.LINK
    docs/rs.ts.strip.md
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
    $Config = Resolve-ProcessorConfig -ProcessorName 'rs.ts.strip' -CallerConfig $Config
}
$ops = @($Config['Operations'])
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }
$protectTsDirectives = $true
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

$stripBlock    = 'block-comments'    -in $ops
$stripInterior = 'interior-comments' -in $ops
$stripDoc      = 'doc-strings'       -in $ops
$stripCB       = 'comment-blocks'    -in $ops
$stripLine     = 'line-comments'     -in $ops
$stripInline   = 'inline-comments'   -in $ops
#endregion

#region MaskLiterals
# Length-preserving, newline-preserving lens: non-newline bytes of string /
# template / regex literals become U+0001 so comment regexes cannot see them.
# Spans computed on $view are offsets into $text. Unclosed quotes mask to EOL
# (templates to EOF) — under-strip, the safe direction. Unclosed /* is NOT
# masked to EOF (that would delete remaining code). `/` is not a regex-start
# lookbehind — the second slash of `//` (and the third of `///`) would otherwise
# lex as a regex literal and hide the comment from classification.
$rxLit = [regex]::new('(?s)`(?:\\.|[^`\\])*`|"(?:\\.|[^"\\\n])*"|''(?:\\.|[^''\\\n])*''|(?<=[=(,:[!&|?+*%~^<>;{}\s-]|^)/(?!/|\*)(?:\\.|[^/\r\n\\])+/[dgimsuvy]*|`(?:\\.|[^`\\])*|"(?:\\.|[^"\\\n])*|''(?:\\.|[^''\\\n])*', 'None')
$chars = $text.ToCharArray()
$fill = [char]0x01
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

#region BlockComments
# /* ... */ — JSDoc /** ... */ is DocString; /**/ is an empty BlockComment.
if ($stripBlock -or $stripInterior -or $stripDoc)
{
    $rx = [regex]::new('(?s)/\*.*?\*/', 'None')
    foreach ($m in $rx.Matches($view))
    {
        $s = $m.Index
        $e = $m.Index + $m.Length
        $isDoc = ($m.Value.StartsWith('/**') -and $m.Value.Length -ge 4 -and $m.Value[3] -ne '/')

        $ls = $s
        while ($ls -gt 0 -and ($view[$ls - 1] -eq ' ' -or $view[$ls - 1] -eq "`t")) { $ls-- }
        $standaloneStart = ($ls -eq 0 -or $view[$ls - 1] -eq "`n")

        $lineEnd = $view.IndexOf("`n", $e)
        if ($lineEnd -eq -1) { $lineEnd = $view.Length }
        $standaloneEnd = ($view.Substring($e, $lineEnd - $e) -notmatch '\S')

        if ($standaloneStart -and $standaloneEnd)
        {
            if ($isDoc) { if (-not $stripDoc) { continue } }
            else { if (-not $stripBlock) { continue } }
            $s = $ls
            if ($e -lt $view.Length -and $view[$e] -eq "`n") { $e++ }
        }
        else
        {
            if ($isDoc) { if (-not $stripDoc) { continue } }
            else { if (-not $stripInterior) { continue } }
        }

        $spansToStrip.Add([pscustomobject]@{ Start = $s; End = $e })
    }
}
#endregion

#region StandaloneLines
if ($stripCB -or $stripLine)
{
    $rxLine = [regex]::new('(?m)^([^\S\n]*)//[^\n]*(\n)?', 'None')
    $standaloneMatches = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($m in $rxLine.Matches($view))
    {
        if ($protectTsDirectives)
        {
            $lineText = $m.Value -replace '\n$', ''
            if ($lineText -match '^[ \t]*///[ \t]*<(?:reference|amd-|ts-)') { continue }
        }

        $slashIdx = $m.Index + $m.Groups[1].Length
        $before = $view.Substring($m.Index, $slashIdx - $m.Index)
        if ($before -match '\S') { continue }

        $lineNum = ($view.Substring(0, $m.Index) -split "`n").Count
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
    $rxInline = [regex]::new('[ \t]*//[^\n]*', 'None')
    foreach ($m in $rxInline.Matches($view))
    {
        if ($protectTsDirectives)
        {
            $lineStartD = $view.LastIndexOf("`n", $m.Index)
            $lineStartD = if ($lineStartD -eq -1) { 0 } else { $lineStartD + 1 }
            $lineEndD = $view.IndexOf("`n", $m.Index)
            if ($lineEndD -eq -1) { $lineEndD = $view.Length }
            $fullLine = $view.Substring($lineStartD, $lineEndD - $lineStartD)
            if ($fullLine -match '^[ \t]*///[ \t]*<(?:reference|amd-|ts-)') { continue }
        }

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
        Processor      = (Resolve-ProcessorLabel -Implementation 'rs.ts.strip' -Config $Config)
        Implementation = 'rs.ts.strip'
        Operations     = @($ops)
    }
}
else { $null }
return Copy-Bag -Item $Item -Resolved $bc -Content $stripped -Record $record
#endregion
