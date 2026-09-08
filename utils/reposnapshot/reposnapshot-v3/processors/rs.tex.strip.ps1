<#
.LINK
    docs/rs.tex.strip.md
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
    $Config = Resolve-ProcessorConfig -ProcessorName 'rs.tex.strip' -CallerConfig $Config
}
$ops = @($Config['Operations'])
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }
$keepWhitespaceSuppression = if ($null -ne $Config['PreserveWhitespaceSuppression']) { [bool]$Config['PreserveWhitespaceSuppression'] } else { $true }
#endregion

#region ContentKey
$bc = Resolve-BagContent -Item $Item
if ($null -eq $bc) { return $Item }

$text = $bc.Text
#endregion

#region LineEndings
$text = $text -replace "`r`n", "`n" -replace "`r", "`n"
#endregion

#region QuickExit
# Global fast-path: if there is no '%' in the text, no TeX comments can exist.
if ($text.IndexOf('%') -eq -1)
{
    $record = if ($includeMeta)
    {
        [pscustomobject]@{
            Processor      = (Resolve-ProcessorLabel -Implementation 'rs.tex.strip' -Config $Config)
            Implementation = 'rs.tex.strip'
            Operations     = @($ops)
        }
    }
    else { $null }
    return Copy-Bag -Item $Item -Resolved $bc -Content $text -Record $record
}
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
# Length-preserving, newline-preserving lens: non-newline characters of protected
# constructs (escaped \%, verbatim environments, inline \verb, \lstinline, \url)
# become U+0001 so comment regexes cannot see them. Spans computed on $view are
# offsets into $text.
$chars = $text.ToCharArray()
$fill = [char]0x01

function _MaskSpan ([char[]]$Arr, [int]$Start, [int]$Len, [char]$FillChar)
{
    $end = $Start + $Len
    $idx = $Start
    while ($idx -lt $end)
    {
        $nl = [System.Array]::IndexOf($Arr, [char]"`n", $idx, $end - $idx)
        if ($nl -eq -1)
        {
            [System.Array]::Fill($Arr, $FillChar, $idx, $end - $idx)
            break
        }
        if ($nl -gt $idx)
        {
            [System.Array]::Fill($Arr, $FillChar, $idx, $nl - $idx)
        }
        $idx = $nl + 1
    }
}

# 1. Escaped percent (\%): odd number of preceding backslashes means literal '%'
# Matches \% and \\\% but not \\% (where \\ is newline and % is comment start).
$rxEscPercent = [regex]::new('(?<!\\)(?:\\\\)*\\%', 'None')
foreach ($m in $rxEscPercent.Matches($text))
{
    $chars[$m.Index + $m.Length - 1] = $fill
}

# 2. Verbatim environments (\begin{verbatim}, lstlisting, minted, filecontents)
if ($text.IndexOf('\begin{', [System.StringComparison]::Ordinal) -ge 0)
{
    $rxVerbatimEnv = [regex]::new(
        '(?sm)^[ \t]*\\begin\{(?:verbatim\*?|lstlisting\*?|minted\*?|filecontents\*?)\}(?:\[[^\n]*\])?(?:\{[^\n]*\})?[\s\S]*?^[ \t]*\\end\{(?:verbatim\*?|lstlisting\*?|minted\*?|filecontents\*?)\}[^\S\n]*(?:\n|$)',
        'None'
    )
    foreach ($m in $rxVerbatimEnv.Matches($text))
    {
        _MaskSpan $chars $m.Index $m.Length $fill
    }
}

# 3. Inline verbatim commands (\verb, \lstinline)
if ($text.IndexOf('\verb', [System.StringComparison]::Ordinal) -ge 0)
{
    $rxVerb = [regex]::new('\\verb\*?([^\s\w\\])[^\n]*?\1', 'None')
    foreach ($m in $rxVerb.Matches($text))
    {
        [System.Array]::Fill($chars, $fill, $m.Index, $m.Length)
    }
}

if ($text.IndexOf('\lstinline', [System.StringComparison]::Ordinal) -ge 0)
{
    $rxLstInline = [regex]::new('\\lstinline(?:\s*\[[^\n]*\])?\s*([^\s\w\\])[^\n]*?\1', 'None')
    foreach ($m in $rxLstInline.Matches($text))
    {
        [System.Array]::Fill($chars, $fill, $m.Index, $m.Length)
    }
}

# 4. URL and path commands (\url{...}, \path{...}, \nolinkurl{...})
if ($text.IndexOf('\url', [System.StringComparison]::Ordinal) -ge 0 -or
    $text.IndexOf('\path', [System.StringComparison]::Ordinal) -ge 0 -or
    $text.IndexOf('\nolinkurl', [System.StringComparison]::Ordinal) -ge 0)
{
    $rxUrl = [regex]::new('\\(?:url|path|nolinkurl)\s*\{[^\n\}]*\}', 'None')
    foreach ($m in $rxUrl.Matches($text))
    {
        [System.Array]::Fill($chars, $fill, $m.Index, $m.Length)
    }
}

$view = [string]::new($chars)
#endregion

#region BlockComments
# Explicit comment environment (\begin{comment} ... \end{comment})
if (($stripBlock -or $stripDoc) -and $view.IndexOf('\begin{comment}', [System.StringComparison]::Ordinal) -ge 0)
{
    $rxCommentEnv = [regex]::new('(?sm)^[ \t]*\\begin\{comment\}[\s\S]*?^[ \t]*\\end\{comment\}[^\S\n]*(?:\n|$)', 'None')
    foreach ($m in $rxCommentEnv.Matches($view))
    {
        $spansToStrip.Add([pscustomobject]@{ Start = $m.Index; End = $m.Index + $m.Length })
    }
}
#endregion

#region StandaloneLines
if ($stripCB -or $stripLine)
{
    $rxLine = [regex]::new('(?m)^([^\S\n]*)%[^\n]*(\n)?', 'None')
    $standaloneMatches = [System.Collections.Generic.List[pscustomobject]]::new()
    $currentLine = 1
    $lastOffset = 0

    foreach ($m in $rxLine.Matches($view))
    {
        $s = $m.Index
        while ($lastOffset -lt $s)
        {
            $nl = $view.IndexOf("`n", $lastOffset, $s - $lastOffset)
            if ($nl -eq -1) { break }
            $currentLine++
            $lastOffset = $nl + 1
        }
        $lastOffset = $s
        $lineNum = $currentLine
        $lineText = $m.Value -replace '\n$', ''

        # Shebang on line 1 is FrontMatter — never stripped
        if ($s -eq 0 -and $lineText.StartsWith('#!')) { continue }

        # Magic TeX / editor directives on header lines (lines 1..5) are FrontMatter — never stripped
        # e.g. % !TeX program = pdflatex, %!TEX root = main.tex, % -*- mode: LaTeX -*-
        if ($lineNum -le 5 -and ($lineText -match '^%\s*(!TEX|!TeX|!BIB|!Bib|-\*-|&)' -or $lineText -match '^%\s*!'))
        {
            continue
        }

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
    $rxInline = [regex]::new('([ \t]*)%([^\n]*)', 'None')
    foreach ($m in $rxInline.Matches($view))
    {
        $lineStart = $view.LastIndexOf("`n", $m.Index)
        $lineStart = if ($lineStart -eq -1) { 0 } else { $lineStart + 1 }
        $before = $view.Substring($lineStart, $m.Index - $lineStart)
        if ($before -notmatch '\S') { continue }

        $leadingWs = $m.Groups[1].Value
        $commentBody = $m.Groups[2].Value
        $hasText = ($commentBody -match '\S')

        if ($keepWhitespaceSuppression)
        {
            # If pure trailing '%' without text (e.g. \foo{% or \bar%), keep it untouched
            if (-not $hasText) { continue }

            # If attached directly to code (e.g. \foo{% comment), strip only the comment body,
            # leaving the '%' token to suppress whitespace.
            if ($leadingWs.Length -eq 0)
            {
                $bodyStart = $m.Index + 1
                $bodyEnd = $m.Index + $m.Length
                if ($bodyEnd -gt $bodyStart)
                {
                    $spansToStrip.Add([pscustomobject]@{ Start = $bodyStart; End = $bodyEnd })
                }
                continue
            }
        }

        # Standard inline comment with whitespace before '%' (e.g. \setlength{...}  % comment)
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
        Processor      = (Resolve-ProcessorLabel -Implementation 'rs.tex.strip' -Config $Config)
        Implementation = 'rs.tex.strip'
        Operations     = @($ops)
    }
}
else { $null }
return Copy-Bag -Item $Item -Resolved $bc -Content $stripped -Record $record
#endregion
