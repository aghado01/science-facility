# See [rs-psstrip.md](docs/rs-psstrip.md) for docstring
param(
    [Parameter(Position = 0)]
    [object]$Item,

    [Parameter(Position = 1)]
    [hashtable]$Config = @{}
)

#region Helper_SplitCommentPopulation
# Pure function: partition the comment-token population at the parse boundary.
function _SplitCommentPopulation {
    param(
        [object[]]$Tokens,
        [System.Management.Automation.Language.Ast]$Ast
    )

    $native = [System.Collections.Generic.List[object]]::new()
    $derived = [System.Collections.Generic.List[pscustomobject]]::new()
    $ck = [System.Management.Automation.Language.TokenKind]::Comment
    $reqs = $Ast.ScriptRequirements

    foreach ($tok in $Tokens) {
        if ($tok.Kind -ne $ck) { continue }

        if ($tok.Text -match '^#requires\b') {
            $derived.Add([pscustomobject]@{
                    Kind                = 'FrontMatter'
                    SubKind             = 'ScriptRequirements'
                    Token               = $tok
                    RequiredPSVersion   = if ($null -ne $reqs) { $reqs.RequiredPSVersion } else { $null }
                    RequiredModules     = if ($null -ne $reqs) { $reqs.RequiredModules } else { $null }
                    RequiredPSEditions  = if ($null -ne $reqs) { $reqs.RequiredPSEditions } else { $null }
                    IsElevationRequired = if ($null -ne $reqs) { [bool]$reqs.IsElevationRequired } else { $false }
                })
        }
        elseif ($tok.Extent.StartOffset -eq 0 -and $tok.Text.StartsWith('#!')) {
            $derived.Add([pscustomobject]@{
                    Kind    = 'FrontMatter'
                    SubKind = 'Shebang'
                    Token   = $tok
                })
        }
        else {
            $native.Add($tok)
        }
    }

    return [pscustomobject]@{ Native = $native; Derived = $derived }
}
#endregion

#region Config
$ops = if ($Config.ContainsKey('Operations')) { @($Config['Operations']) } else { @('block-comments', 'doc-strings', 'comment-blocks', 'trim-inner', 'line-comments') }
$includeMeta = if ($null -ne $Config['IncludeMeta']) { [bool]$Config['IncludeMeta'] } else { $true }
#endregion

#region ContentKey
$bc = Resolve-BagContent -Item $Item
if ($null -eq $bc) { return $Item }

$text = $bc.Text
#endregion

#region Parse
$tokensRef = [ref]$null
$errorsRef = [ref]$null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($text, $tokensRef, $errorsRef)
$tokens = @($tokensRef.Value)
$errors = @($errorsRef.Value)

$parseErrors = $null
if ($errors.Count -gt 0) {
    $msgs = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $errors) { $msgs.Add($e.Message) }
    $parseErrors = @($msgs)
}
#endregion

#region RouteSelection
# Tolerance-first: engage regex fallback only on unclosed string tokens or explicit override.
$useFallback = $false
if ([bool]$Config['ForceRegexFallback']) { $useFallback = $true }
elseif ($errors.Count -gt 0) {
    foreach ($e in $errors) {
        if ($e.ErrorId -in @('TerminatorExpectedAtEndOfString', 'WhitespaceBeforeHereStringFooter')) {
            $useFallback = $true
            break
        }
    }
}

$hsStore = [System.Collections.Generic.List[string]]::new()
$HS_OPEN = [char]0xE000
$HS_CLOSE = [char]0xE001
#endregion

if ($useFallback) {
    #region Fallback_HereStrings
    $maskHereStrings = if ($null -ne $Config['MaskHereStrings']) { [bool]$Config['MaskHereStrings'] } else { $true }
    if ($maskHereStrings) {
        $rxHs = [regex]::new('(?s)@([''"])[ \t]*\r?\n.*?\n\1@')
        $text = $rxHs.Replace($text, {
                param($m)
                $hsIdx = $hsStore.Count
                $hsStore.Add($m.Value)
                "$HS_OPEN$hsIdx$HS_CLOSE"
            })

        $hsGuard = 0
        while ($hsGuard++ -lt 100) {
            $mOpen = [regex]::Match($text, '@([''"])[ \t]*\r?\n')
            if (-not $mOpen.Success) { break }
            $q = $mOpen.Groups[1].Value
            $rest = $text.Substring($mOpen.Index)
            $mClose = [regex]::Match($rest, ('(?m)^[ \t]*' + $q + '@'))
            $hsEnd = if ($mClose.Success) { $mOpen.Index + $mClose.Index + $mClose.Length } else { $text.Length }
            $hsIdx = $hsStore.Count
            $hsStore.Add($text.Substring($mOpen.Index, $hsEnd - $mOpen.Index))
            $text = $text.Substring(0, $mOpen.Index) + "$HS_OPEN$hsIdx$HS_CLOSE" + $text.Substring($hsEnd)
        }
    }

    $spansToStrip = [System.Collections.Generic.List[pscustomobject]]::new()
    $stripBlock = ('block-comments' -in $ops) -or ('doc-strings' -in $ops)
    $stripCB = 'comment-blocks' -in $ops
    $stripLine = 'line-comments' -in $ops
    $stripInline = 'inline-comments' -in $ops
    #endregion

    #region Fallback_BlockComments
    if ($stripBlock) {
        $rx = [regex]::new('(?s)<#.*?#>', 'None')
        foreach ($m in $rx.Matches($text)) {
            $s = $m.Index
            $e = $m.Index + $m.Length
            $ls = $s
            while ($ls -gt 0 -and ($text[$ls - 1] -eq ' ' -or $text[$ls - 1] -eq "`t")) { $ls-- }
            if ($ls -eq 0 -or $text[$ls - 1] -eq "`n" -or $text[$ls - 1] -eq "`r") { $s = $ls }
            if ($e -lt $text.Length) {
                if ($text[$e] -eq "`r") { $e++; if ($e -lt $text.Length -and $text[$e] -eq "`n") { $e++ } }
                elseif ($text[$e] -eq "`n") { $e++ }
            }
            $spansToStrip.Add([pscustomobject]@{ Start = $s; End = $e })
        }
    }
    #endregion

    #region Fallback_StandaloneLines
    if ($stripCB -or $stripLine) {
        $rxLine = [regex]::new('(?m)^([^\S\r\n]*)#(?!(?i:requires)\b)[^\r\n]*(\r?\n)?', 'None')
        $standaloneMatches = [System.Collections.Generic.List[pscustomobject]]::new()
        $textLines = $text -split "`n"
        foreach ($m in $rxLine.Matches($text)) {
            $lineStart = $m.Index
            $hashIdx = $m.Index + $m.Groups[1].Length
            $before = $text.Substring($lineStart, $hashIdx - $lineStart)
            if ($before -match '\S') { continue }
            if ($m.Index -eq 0 -and $m.Value.StartsWith('#!')) { continue }

            $lineNum = ($text.Substring(0, $m.Index) -split "`n").Count

            $standaloneMatches.Add([pscustomobject]@{
                    LineNum = $lineNum
                    Start   = $m.Index
                    End     = $m.Index + $m.Length
                })
        }

        $runStartI = -1
        $runEndI = -1
        $cbFlags = @($false) * $standaloneMatches.Count

        for ($i = 0; $i -lt $standaloneMatches.Count; $i++) {
            $cur2 = $standaloneMatches[$i]
            if ($runStartI -eq -1) {
                $runStartI = $i; $runEndI = $i
            }
            elseif ($cur2.LineNum -eq $standaloneMatches[$runEndI].LineNum + 1) {
                $runEndI = $i
            }
            else {
                if ($runEndI -gt $runStartI) { for ($j = $runStartI; $j -le $runEndI; $j++) { $cbFlags[$j] = $true } }
                $runStartI = $i; $runEndI = $i
            }
        }
        if ($runStartI -ne -1 -and $runEndI -gt $runStartI) { for ($j = $runStartI; $j -le $runEndI; $j++) { $cbFlags[$j] = $true } }

        for ($i = 0; $i -lt $standaloneMatches.Count; $i++) {
            $shouldStrip2 = if ($cbFlags[$i]) { $stripCB } else { $stripLine }
            if (-not $shouldStrip2) { continue }
            $sm = $standaloneMatches[$i]
            $ls2 = $sm.Start
            while ($ls2 -gt 0 -and ($text[$ls2 - 1] -eq ' ' -or $text[$ls2 - 1] -eq "`t")) { $ls2-- }
            $s2 = if ($ls2 -eq 0 -or $text[$ls2 - 1] -eq "`n" -or $text[$ls2 - 1] -eq "`r") { $ls2 } else { $sm.Start }
            $spansToStrip.Add([pscustomobject]@{ Start = $s2; End = $sm.End })
        }
    }
    #endregion

    #region Fallback_InlineComments
    if ($stripInline) {
        $rxInline = [regex]::new('(?m)[ \t]*#(?!(?i:requires)\b)[^\r\n]*', 'None')
        foreach ($m in $rxInline.Matches($text)) {
            $lineStart = $text.LastIndexOf("`n", $m.Index)
            $lineStart = if ($lineStart -eq -1) { 0 } else { $lineStart + 1 }
            $before2 = $text.Substring($lineStart, $m.Index - $lineStart)
            if ($before2 -notmatch '\S') { continue }
            $spansToStrip.Add([pscustomobject]@{ Start = $m.Index; End = $m.Index + $m.Length })
        }
    }
    #endregion
}
else {
    #region AST_BodyExtents
    $bodyExtents = [System.Collections.Generic.List[System.Management.Automation.Language.IScriptExtent]]::new()

    $bodyNodes = $ast.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $node -is [System.Management.Automation.Language.TypeDefinitionAst]
        },
        $true
    )
    foreach ($node in $bodyNodes) { $bodyExtents.Add($node.Extent) }
    #endregion

    #region AST_NativeClassification
    $lines = $text -split "`n"
    $population = _SplitCommentPopulation -Tokens $tokens -Ast $ast
    $population.Native.Sort(
        [System.Comparison[object]] { param($a, $b) $a.Extent.StartOffset.CompareTo($b.Extent.StartOffset) })
    $commentTokens = $population.Native

    $classified = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($tok in $commentTokens) {
        $so = $tok.Extent.StartOffset
        $eo = $tok.Extent.EndOffset
        $line = $tok.Extent.StartLineNumber
        $col = $tok.Extent.StartColumnNumber

        if ($tok.Text -match '^<#') {
            $isInBody = $false
            foreach ($ext in $bodyExtents) {
                if ($so -ge $ext.StartOffset -and $eo -le $ext.EndOffset) { $isInBody = $true; break }
            }
            $kind = if ($isInBody) { 'DocString' } else { 'BlockComment' }
        }
        else {
            $kind = 'LineComment'
            $lineIdx = $line - 1
            if ($lineIdx -ge 0 -and $lineIdx -lt $lines.Count) {
                $lineText = $lines[$lineIdx]
                $beforeLen = [Math]::Min($col - 1, $lineText.Length)
                if ($beforeLen -gt 0 -and $lineText.Substring(0, $beforeLen) -match '\S') {
                    $kind = 'InlineComment'
                }
            }
        }

        $classified.Add([pscustomobject]@{
                Token    = $tok
                Kind     = $kind
                StartOff = $so
                EndOff   = $eo
                LineNum  = $line
            })
    }
    #endregion

    #region AST_FrontMatter
    if ($population.Derived.Count -gt 0) {
        foreach ($fm in $population.Derived) {
            $classified.Add([pscustomobject]@{
                    Token    = $fm.Token
                    Kind     = 'FrontMatter'
                    StartOff = $fm.Token.Extent.StartOffset
                    EndOff   = $fm.Token.Extent.EndOffset
                    LineNum  = $fm.Token.Extent.StartLineNumber
                })
        }
        $classified.Sort([System.Comparison[object]] { param($a, $b) $a.StartOff.CompareTo($b.StartOff) })
    }
    #endregion

    #region AST_CommentBlockRuns
    $runStartI = -1
    $runEndI = -1

    for ($i = 0; $i -lt $classified.Count; $i++) {
        $c = $classified[$i]
        if ($c.Kind -ne 'LineComment') {
            if ($runStartI -ne -1 -and $runEndI -gt $runStartI) {
                for ($j = $runStartI; $j -le $runEndI; $j++) { $classified[$j].Kind = 'CommentBlock' }
            }
            $runStartI = -1
            $runEndI = -1
            continue
        }

        if ($runStartI -eq -1) {
            $runStartI = $i
            $runEndI = $i
        }
        elseif ($c.LineNum -eq $classified[$runEndI].LineNum + 1) {
            $runEndI = $i
        }
        else {
            if ($runEndI -gt $runStartI) {
                for ($j = $runStartI; $j -le $runEndI; $j++) { $classified[$j].Kind = 'CommentBlock' }
            }
            $runStartI = $i
            $runEndI = $i
        }
    }
    if ($runStartI -ne -1 -and $runEndI -gt $runStartI) {
        for ($j = $runStartI; $j -le $runEndI; $j++) { $classified[$j].Kind = 'CommentBlock' }
    }
    #endregion

    #region AST_BuildSpans
    $spansToStrip = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($c in $classified) {
        $shouldStrip = switch ($c.Kind) {
            'FrontMatter' { $false }
            'BlockComment' { 'block-comments' -in $ops }
            'DocString' { 'doc-strings' -in $ops }
            'CommentBlock' { 'comment-blocks' -in $ops }
            'LineComment' { 'line-comments' -in $ops }
            'InlineComment' { 'inline-comments' -in $ops }
            default { $false }
        }
        if (-not $shouldStrip) { continue }

        $spanStart = $c.StartOff
        $spanEnd = $c.EndOff

        if ($c.Kind -eq 'InlineComment') {
            $ws = $spanStart
            while ($ws -gt 0 -and ($text[$ws - 1] -eq ' ' -or $text[$ws - 1] -eq "`t")) { $ws-- }
            $spanStart = $ws
        }
        else {
            $ls = $spanStart
            while ($ls -gt 0 -and ($text[$ls - 1] -eq ' ' -or $text[$ls - 1] -eq "`t")) { $ls-- }
            if ($ls -eq 0 -or $text[$ls - 1] -eq "`n" -or $text[$ls - 1] -eq "`r") {
                $spanStart = $ls
            }

            if ($spanEnd -lt $text.Length) {
                if ($text[$spanEnd] -eq "`r") {
                    $spanEnd++
                    if ($spanEnd -lt $text.Length -and $text[$spanEnd] -eq "`n") { $spanEnd++ }
                }
                elseif ($text[$spanEnd] -eq "`n") {
                    $spanEnd++
                }
            }
        }

        $spansToStrip.Add([pscustomobject]@{ Start = $spanStart; End = $spanEnd })
    }
    #endregion
}

#region MergeSpans
$merged = [System.Collections.Generic.List[pscustomobject]]::new()

if ($spansToStrip.Count -gt 0) {
    $spansToStrip.Sort([System.Comparison[object]] { param($a, $b) $a.Start.CompareTo($b.Start) })
    $sorted = $spansToStrip
    $cur = [pscustomobject]@{ Start = $sorted[0].Start; End = $sorted[0].End }

    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $nxt = $sorted[$i]
        if ($nxt.Start -le $cur.End) {
            if ($nxt.End -gt $cur.End) { $cur = [pscustomobject]@{ Start = $cur.Start; End = $nxt.End } }
        }
        else {
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

foreach ($span in $merged) {
    if ($span.Start -gt $pos) {
        $null = $sb.Append($text.Substring($pos, $span.Start - $pos))
    }
    $pos = $span.End
}
if ($pos -lt $text.Length) {
    $null = $sb.Append($text.Substring($pos))
}

$stripped = $sb.ToString()

if ($hsStore.Count -gt 0) {
    $stripped = [regex]::Replace($stripped, "$HS_OPEN(\d+)$HS_CLOSE", { param($m) $hsStore[[int]$m.Groups[1].Value] })
}
#endregion

#region Emit
$recordObj = $null
if ($includeMeta) {
    $record = [ordered]@{
        Processor  = 'rs-psstrip'
        Operations = @($ops)
    }
    if ($null -ne $parseErrors) { $record['ParseErrors'] = $parseErrors }
    if ($useFallback) { $record['FallbackMode'] = 'regex' }
    $recordObj = [pscustomobject]$record
}

return Copy-Bag -Item $Item -Resolved $bc -Content $stripped -Record $recordObj
#endregion
