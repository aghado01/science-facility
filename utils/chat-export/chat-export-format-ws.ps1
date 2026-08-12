# Shared final-stage whitespace normalization for chat-export Markdown.
#
# This adapts reposnapshot-v3/processors/format-ws.ps1 to Markdown rather than
# importing its repository-snapshot processor contract. Operation order is a
# correctness invariant: transport and Unicode cleanup happen first, followed
# by Markdown-aware trailing/inner/blank cleanup, then document trimming.

function script:Get-ChatExportFenceInfo
{
    param(
        [AllowEmptyString()]
        [string]$Line
    )

    $match = [regex]::Match(
        $Line,
        '^(?<prefix>[ ]{0,3}(?:(?:>[\t ]?)+)?)(?<run>`{3,}|~{3,})(?<rest>.*)$')
    if (-not $match.Success) { return $null }

    $run = $match.Groups['run'].Value
    $prefix = $match.Groups['prefix'].Value
    return [pscustomobject]@{
        Prefix     = $prefix
        Character  = $run.Substring(0, 1)
        Length     = $run.Length
        Rest       = $match.Groups['rest'].Value
        QuoteDepth = [regex]::Matches($prefix, '>').Count
    }
}

function script:Remove-ChatExportInvisibleCharacters
{
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    # Deliberately matches reposnapshot's strip-zwsp set. U+FEFF is included
    # here as well as in the leading-BOM operation because embedded BOMs occur
    # in copied transcript bodies.
    return $Text -replace '[\u200B\u200C\u200D\u2060\uFEFF]', ''
}

function script:Normalize-ChatExportLiteralText
{
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    try { $normalized = $normalized.Normalize([System.Text.NormalizationForm]::FormC) } catch {}
    return script:Remove-ChatExportInvisibleCharacters -Text $normalized
}

function script:Normalize-ChatExportJsonNodeStrings
{
    param(
        [AllowNull()]
        [System.Text.Json.Nodes.JsonNode]$Node
    )

    if ($null -eq $Node) { return $null }

    if ($Node -is [System.Text.Json.Nodes.JsonObject])
    {
        $properties = @($Node.AsObject())
        $normalizedKeys = @($properties | ForEach-Object {
                script:Normalize-ChatExportLiteralText -Text $_.Key
            })
        $distinctKeys = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
        foreach ($key in $normalizedKeys) { [void]$distinctKeys.Add($key) }
        $canNormalizeKeys = $distinctKeys.Count -eq $normalizedKeys.Count

        $normalizedObject = [System.Text.Json.Nodes.JsonObject]::new()
        for ($propertyIndex = 0;
            $propertyIndex -lt $properties.Count;
            $propertyIndex++)
        {
            $property = $properties[$propertyIndex]
            $key = if ($canNormalizeKeys)
            { $normalizedKeys[$propertyIndex] } else { $property.Key }
            $normalizedChild = script:Normalize-ChatExportJsonNodeStrings `
                -Node $property.Value
            $normalizedObject.Add($key, $normalizedChild)
        }
        return ,$normalizedObject
    }

    if ($Node -is [System.Text.Json.Nodes.JsonArray])
    {
        $normalizedArray = [System.Text.Json.Nodes.JsonArray]::new()
        for ($itemIndex = 0; $itemIndex -lt $Node.AsArray().Count; $itemIndex++)
        {
            $normalizedItem = script:Normalize-ChatExportJsonNodeStrings `
                -Node $Node[$itemIndex]
            [void]$normalizedArray.Add($normalizedItem)
        }
        return ,$normalizedArray
    }

    if ($Node -is [System.Text.Json.Nodes.JsonValue] -and
        $Node.GetValueKind() -eq [System.Text.Json.JsonValueKind]::String)
    {
        $normalizedValue = script:Normalize-ChatExportLiteralText -Text $Node.ToString()
        return ,[System.Text.Json.Nodes.JsonValue]::Create($normalizedValue)
    }

    return ,$Node.DeepClone()
}

function script:Format-ChatExportToolJson
{
    param(
        [AllowEmptyString()]
        [string]$Json
    )

    try
    {
        $node = [System.Text.Json.Nodes.JsonNode]::Parse($Json)
        if ($null -eq $node)
        {
            return [pscustomobject]@{ Success = $true; Text = 'null' }
        }

        $node = script:Normalize-ChatExportJsonNodeStrings -Node $node
        $jsonOptions = [System.Text.Json.JsonSerializerOptions]::new()
        # The payload is inside a Markdown fence, not an HTML script element.
        # Retaining printable Unicode/HTML characters avoids introducing
        # unrelated escape noise while the structured rewrite stays valid JSON.
        $jsonOptions.Encoder =
            [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
        return [pscustomobject]@{
            Success = $true
            Text    = $node.ToJsonString($jsonOptions)
        }
    }
    catch
    {
        # Truncated and string-valued Codex tool inputs are not necessarily
        # JSON. They remain a literal fenced payload and receive only global
        # character cleanup.
        return [pscustomobject]@{ Success = $false; Text = $Json }
    }
}

function script:Remove-ChatExportQuoteContainers
{
    param(
        [AllowEmptyString()]
        [string]$Line,
        [int]$Depth
    )

    $content = $Line
    for ($quoteIndex = 0; $quoteIndex -lt $Depth; $quoteIndex++)
    {
        $match = [regex]::Match($content, '^[ ]{0,3}>[\t ]?')
        if (-not $match.Success) { return $null }
        $content = $content.Substring($match.Length)
    }
    return $content
}

function script:Test-ChatExportToolJsonFence
{
    param(
        [string[]]$Lines,
        [int]$OpeningIndex,
        [object]$OpeningFence
    )

    if ($OpeningFence.Rest.Trim() -ne 'json') { return $false }

    for ($previousIndex = $OpeningIndex - 1; $previousIndex -ge 0; $previousIndex--)
    {
        if ([string]::IsNullOrWhiteSpace($Lines[$previousIndex])) { continue }
        $label = script:Remove-ChatExportQuoteContainers `
            -Line ([string]$Lines[$previousIndex]) `
            -Depth $OpeningFence.QuoteDepth
        return $null -ne $label -and $label -match '^\*\*\[tool: .*\]\*\*$'
    }

    return $false
}

function script:Compress-ChatExportInlineSpaces
{
    param(
        [AllowEmptyString()]
        [string]$Line
    )

    # Inline code spans carry literal spacing. Apply trim-inner only to the
    # regions outside matched backtick spans, preserving the delimiters and
    # their content byte-for-character after the global Unicode cleanup.
    $output = [System.Text.StringBuilder]::new()
    $outsideStart = 0
    $cursor = 0
    $hasMatchedSpan = $false

    function Compress-OutsideSegment
    {
        param(
            [AllowEmptyString()]
            [string]$Text,
            [bool]$HasLeftBoundary,
            [bool]$HasRightBoundary
        )

        $leftSentinel = if ($HasLeftBoundary) { 'X' } else { '' }
        $rightSentinel = if ($HasRightBoundary) { 'X' } else { '' }
        $working = $leftSentinel + $Text + $rightSentinel
        $working = $working -replace '(?<=\S) {2,}(?=\S)', ' '
        return $working.Substring(
            $leftSentinel.Length,
            $working.Length - $leftSentinel.Length - $rightSentinel.Length)
    }

    while ($cursor -lt $Line.Length)
    {
        if ($Line[$cursor] -ne '`')
        {
            $cursor++
            continue
        }

        $runStart = $cursor
        while ($cursor -lt $Line.Length -and $Line[$cursor] -eq '`') { $cursor++ }
        $runLength = $cursor - $runStart
        $closingStart = -1
        $search = $cursor

        while ($search -lt $Line.Length)
        {
            if ($Line[$search] -ne '`')
            {
                $search++
                continue
            }

            $candidateStart = $search
            while ($search -lt $Line.Length -and $Line[$search] -eq '`') { $search++ }
            if (($search - $candidateStart) -eq $runLength)
            {
                $closingStart = $candidateStart
                break
            }
        }

        if ($closingStart -lt 0)
        {
            $cursor = $runStart + $runLength
            continue
        }

        $outside = $Line.Substring($outsideStart, $runStart - $outsideStart)
        [void]$output.Append((Compress-OutsideSegment `
                    -Text $outside `
                    -HasLeftBoundary $hasMatchedSpan `
                    -HasRightBoundary $true))
        $spanLength = ($closingStart + $runLength) - $runStart
        [void]$output.Append($Line.Substring($runStart, $spanLength))
        $cursor = $closingStart + $runLength
        $outsideStart = $cursor
        $hasMatchedSpan = $true
    }

    $tail = $Line.Substring($outsideStart)
    [void]$output.Append((Compress-OutsideSegment `
                -Text $tail `
                -HasLeftBoundary $hasMatchedSpan `
                -HasRightBoundary $false))
    return $output.ToString()
}

function script:Test-ChatExportIndentedCodeLine
{
    param(
        [AllowEmptyString()]
        [string]$Line
    )

    # Remove generated/nested blockquote containers before testing the content
    # indentation. Four spaces or a tab is Markdown code and remains literal.
    $content = $Line -replace '^[ ]{0,3}(?:(?:>[\t ]?)+)', ''
    return $content -match '^(?: {4}|\t)'
}

function script:Format-ChatExportProseLine
{
    param(
        [AllowEmptyString()]
        [string]$Line
    )

    if (script:Test-ChatExportIndentedCodeLine -Line $Line)
    {
        return $Line
    }

    # Keep Markdown's intentional two-space hard break, while normalizing a
    # longer all-space suffix to its canonical two spaces. Other trailing
    # Unicode whitespace is removed as in reposnapshot's trim-trailing op.
    $hasHardBreak = $Line -match '\S {2,}$'
    $trimmed = $Line.TrimEnd()
    if ($hasHardBreak) { $trimmed += '  ' }

    # List-marker spacing determines continuation indentation and can turn a
    # nested code/list block into ordinary prose. Preserve that prefix exactly
    # and compact only the list item's prose body.
    $listItem = [regex]::Match(
        $trimmed,
        '^(?<prefix>[ ]{0,3}(?:(?:>[\t ]?)+)?[ ]{0,3}(?:[-+*]|\d{1,9}[.)])[\t ]+)(?<body>.*)$')
    if ($listItem.Success)
    {
        return $listItem.Groups['prefix'].Value +
            (script:Compress-ChatExportInlineSpaces `
                -Line $listItem.Groups['body'].Value)
    }

    return script:Compress-ChatExportInlineSpaces -Line $trimmed
}

function script:Protect-ChatExportSynthesizedFence
{
    param(
        [AllowEmptyString()]
        [string]$OriginalLine,

        [AllowEmptyString()]
        [string]$NormalizedLine
    )

    if ($null -ne (script:Get-ChatExportFenceInfo -Line $OriginalLine))
    {
        return $NormalizedLine
    }

    $normalizedFence = script:Get-ChatExportFenceInfo -Line $NormalizedLine
    if ($null -eq $normalizedFence) { return $NormalizedLine }

    # Removing a zero-width character from `​`` must not silently turn prose
    # into a Markdown fence. Escape the synthesized delimiter; existing fences
    # are handled separately and retain their structural role.
    return $normalizedFence.Prefix + '\' +
        ([string]::new([char]$normalizedFence.Character, $normalizedFence.Length)) +
        $normalizedFence.Rest
}

function Format-ChatExportMarkdown
{
    <#
    .SYNOPSIS
        Normalize a rendered chat-export Markdown document.

    .DESCRIPTION
        Applies the reposnapshot whitespace operations in a Markdown-aware
        form: LF line endings, BOM removal, NFC, removal of U+200B/U+200C/
        U+200D/U+2060/U+FEFF, trailing whitespace cleanup, inner-space
        compaction, at most two blank lines, and document trimming.

        Fenced payloads, inline code, and indented code retain significant
        spacing. Markdown hard breaks are retained as exactly two spaces.
        Fences are lengthened when necessary so invisible-character removal
        cannot synthesize a closing delimiter inside a payload. A non-empty
        document always ends in exactly one LF. Generated tool-call JSON is
        parsed when valid so escaped string values and property names receive
        conservative EOL, NFC, and invisible-character normalization without
        collapsing semantic spaces.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Markdown
    )

    if ($null -eq $Markdown) { return '' }

    # Fixed global order adapted from reposnapshot format-ws: lf, no-bom, nfc.
    $text = $Markdown -replace "`r`n", "`n" -replace "`r", "`n"
    $text = $text -replace '^\uFEFF', ''
    try { $text = $text.Normalize([System.Text.NormalizationForm]::FormC) } catch {}

    $lines = @($text -split "`n")
    $formatted = [System.Collections.Generic.List[object]]::new()
    $firstContentLine = 0
    while ($firstContentLine -lt $lines.Count -and $lines[$firstContentLine].Length -eq 0)
    {
        $firstContentLine++
    }

    $frontmatterEnd = -1
    if ($firstContentLine -lt $lines.Count -and $lines[$firstContentLine] -eq '---')
    {
        for ($frontmatterCursor = $firstContentLine + 1;
            $frontmatterCursor -lt $lines.Count;
            $frontmatterCursor++)
        {
            if ($lines[$frontmatterCursor] -eq '---')
            {
                $frontmatterEnd = $frontmatterCursor
                break
            }
        }
    }

    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++)
    {
        $line = [string]$lines[$lineIndex]
        $openFence = script:Get-ChatExportFenceInfo -Line $line
        $isBacktickOpening = $null -ne $openFence -and
            ($openFence.Character -ne '`' -or $openFence.Rest -notmatch '`')

        if ($isBacktickOpening)
        {
            $closingIndex = -1
            for ($candidateIndex = $lineIndex + 1;
                $candidateIndex -lt $lines.Count;
                $candidateIndex++)
            {
                $candidate = script:Get-ChatExportFenceInfo -Line ([string]$lines[$candidateIndex])
                if ($null -ne $candidate -and
                    $candidate.Character -eq $openFence.Character -and
                    $candidate.QuoteDepth -eq $openFence.QuoteDepth -and
                    $candidate.Length -ge $openFence.Length -and
                    $candidate.Rest -match '^[\t ]*$')
                {
                    $closingIndex = $candidateIndex
                    break
                }
            }

            if ($closingIndex -lt 0)
            {
                # An unclosed Markdown fence protects the remainder of the
                # document. Preserve its literal spacing while still applying
                # the global invisible-character cleanup.
                for ($protectedIndex = $lineIndex;
                    $protectedIndex -lt $lines.Count;
                    $protectedIndex++)
                {
                    $protectedLine = script:Remove-ChatExportInvisibleCharacters `
                        -Text ([string]$lines[$protectedIndex])
                    if ($protectedIndex -gt $lineIndex)
                    {
                        $protectedLine = script:Protect-ChatExportSynthesizedFence `
                            -OriginalLine ([string]$lines[$protectedIndex]) `
                            -NormalizedLine $protectedLine
                    }
                    $formatted.Add([pscustomobject]@{
                            Text      = $protectedLine
                            Protected = $true
                        })
                }
                break
            }

            $normalizedContent = [System.Collections.Generic.List[string]]::new()
            $maximumDelimiterRun = 0
            for ($contentIndex = $lineIndex + 1;
                $contentIndex -lt $closingIndex;
                $contentIndex++)
            {
                $contentLine = script:Remove-ChatExportInvisibleCharacters `
                    -Text ([string]$lines[$contentIndex])
                $normalizedContent.Add($contentLine)

                $contentFence = script:Get-ChatExportFenceInfo -Line $contentLine
                if ($null -ne $contentFence -and
                    $contentFence.Character -eq $openFence.Character -and
                    $contentFence.QuoteDepth -eq $openFence.QuoteDepth -and
                    $contentFence.Rest -match '^[\t ]*$')
                {
                    $maximumDelimiterRun = [Math]::Max(
                        $maximumDelimiterRun, $contentFence.Length)
                }
            }

            if (script:Test-ChatExportToolJsonFence `
                    -Lines $lines `
                    -OpeningIndex $lineIndex `
                    -OpeningFence $openFence)
            {
                $jsonLines = [System.Collections.Generic.List[string]]::new()
                $canRemoveContainers = $true
                foreach ($contentLine in $normalizedContent)
                {
                    $jsonLine = script:Remove-ChatExportQuoteContainers `
                        -Line $contentLine `
                        -Depth $openFence.QuoteDepth
                    if ($null -eq $jsonLine)
                    {
                        $canRemoveContainers = $false
                        break
                    }
                    $jsonLines.Add($jsonLine)
                }

                if ($canRemoveContainers)
                {
                    $jsonResult = script:Format-ChatExportToolJson `
                        -Json ($jsonLines -join "`n")
                    if ($jsonResult.Success)
                    {
                        $normalizedContent.Clear()
                        foreach ($jsonLine in @($jsonResult.Text -split "`n"))
                        {
                            $container = if ($openFence.QuoteDepth -gt 0)
                            { $openFence.Prefix } else { '' }
                            $normalizedContent.Add($container + $jsonLine)
                        }
                    }
                }
            }

            $delimiterLength = if ($maximumDelimiterRun -ge $openFence.Length)
            {
                $maximumDelimiterRun + 1
            }
            else { $openFence.Length }
            $delimiter = [string]::new([char]$openFence.Character, $delimiterLength)
            $normalizedOpeningRest = script:Remove-ChatExportInvisibleCharacters `
                -Text $openFence.Rest

            $formatted.Add([pscustomobject]@{
                    Text      = $openFence.Prefix + $delimiter + $normalizedOpeningRest
                    Protected = $true
                })
            foreach ($contentLine in $normalizedContent)
            {
                $formatted.Add([pscustomobject]@{
                        Text      = $contentLine
                        Protected = $true
                    })
            }

            $closingFence = script:Get-ChatExportFenceInfo `
                -Line ([string]$lines[$closingIndex])
            $formatted.Add([pscustomobject]@{
                    Text      = $closingFence.Prefix + $delimiter
                    Protected = $true
                })
            $lineIndex = $closingIndex
            continue
        }

        $normalizedLine = script:Remove-ChatExportInvisibleCharacters -Text $line
        $normalizedLine = script:Protect-ChatExportSynthesizedFence `
            -OriginalLine $line `
            -NormalizedLine $normalizedLine

        $inFrontmatter = $frontmatterEnd -ge 0 -and
            $lineIndex -ge $firstContentLine -and
            $lineIndex -le $frontmatterEnd
        if (-not $inFrontmatter)
        {
            $normalizedLine = script:Format-ChatExportProseLine -Line $normalizedLine
        }

        $formatted.Add([pscustomobject]@{
                Text      = $normalizedLine
                Protected = $inFrontmatter
            })
    }

    # max-blank-2 applies only to ordinary Markdown whitespace. Blank lines in
    # fenced payloads are protected and therefore retain their exact count.
    $resultLines = [System.Collections.Generic.List[string]]::new()
    $blankRun = 0
    foreach ($entry in $formatted)
    {
        if (-not $entry.Protected -and $entry.Text.Length -eq 0)
        {
            $blankRun++
            if ($blankRun -le 2) { $resultLines.Add('') }
            continue
        }

        $blankRun = 0
        $resultLines.Add([string]$entry.Text)
    }

    # trim-doc, adapted to retain the exporters' established single final LF.
    $result = ($resultLines -join "`n") -replace '^\n+', '' -replace '\n+$', ''
    if ($result.Length -eq 0) { return '' }
    return $result + "`n"
}
