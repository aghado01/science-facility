# codex-jso-markdown.ps1 — Render Codex exchange envelopes as Markdown

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'chat-export-output.ps1')

function script:ConvertTo-CodexDisplayJson
{
    param(
        [object]$Value,
        [Nullable[int]]$MaxLength
    )

    if ($null -eq $Value) { return '' }
    $text = if ($Value -is [string])
    {
        [string]$Value
    }
    else
    {
        $Value | ConvertTo-Json -Depth 100 -Compress
    }

    if ($null -ne $MaxLength -and $text.Length -gt $MaxLength)
    {
        return $text.Substring(0, $MaxLength.Value) + ' ... [truncated]'
    }
    return $text
}

function script:Quote-CodexMarkdownBlock
{
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($line in ($Text.TrimEnd() -split "`n"))
    {
        if ($line.Length -eq 0) { [void]$sb.Append(">`n") }
        else { [void]$sb.Append("> $($line.TrimEnd())`n") }
    }
    return $sb.ToString().TrimEnd()
}

function script:Get-CodexToolCallMarkdown
{
    param(
        [object]$Record,
        [System.Collections.Generic.HashSet[string]]$ExcludeSet,
        [Nullable[int]]$MaxToolInputLength,
        [string]$Format
    )

    $inputText = script:ConvertTo-CodexDisplayJson `
        -Value $Record.input -MaxLength $MaxToolInputLength
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("**[tool: $($Record.tool_name)]**`n")
    [void]$sb.Append('```json' + "`n$inputText`n" + '```')

    if (-not $ExcludeSet.Contains('tool-results') -and $null -ne $Record.response)
    {
        $resultText = script:ConvertTo-CodexDisplayJson `
            -Value $Record.response.content -MaxLength $null
        $shortId = [string]$Record.tool_use_id
        if ($shortId.Length -gt 16) { $shortId = $shortId.Substring(0, 16) + '...' }
        [void]$sb.Append("`n`n**[result: $shortId]**`n")
        [void]$sb.Append('```text' + "`n$($resultText.TrimEnd())`n" + '```')
    }

    $markdown = $sb.ToString()
    if ($Format -eq 'House')
    {
        return script:Quote-CodexMarkdownBlock $markdown
    }
    return $markdown
}

function script:Get-CodexMarkdownFrontmatter
{
    param(
        [string]$Format,
        [string[]]$Exclude,
        [string]$ThreadId,
        [System.Collections.Generic.HashSet[string]]$Models,
        [int]$ExchangeCount,
        [string]$UserLabel
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("---`n")
    [void]$sb.Append("provider: codex`n")
    [void]$sb.Append("format: $Format`n")
    [void]$sb.Append("exported_at: $([datetime]::UtcNow.ToString('o'))`n")
    if ($ThreadId) { [void]$sb.Append("thread_id: $ThreadId`n") }
    [void]$sb.Append("exchanges: $ExchangeCount`n")
    if ($UserLabel) { [void]$sb.Append("user_label: $UserLabel`n") }

    if ($Models.Count -gt 0)
    {
        [void]$sb.Append("models:`n")
        foreach ($model in ($Models | Sort-Object))
        {
            [void]$sb.Append("  - $model`n")
        }
    }
    if ($Exclude -and $Exclude.Count -gt 0)
    {
        [void]$sb.Append("exclude:`n")
        foreach ($name in $Exclude)
        {
            [void]$sb.Append("  - $name`n")
        }
    }
    [void]$sb.Append("---`n`n")
    return $sb.ToString()
}

function ConvertTo-CodexMarkdown
{
    <#
    .SYNOPSIS
        Render Codex exchange-envelope JSONL as Markdown.
    .PARAMETER NormalizeWhitespace
        Apply the shared final-Markdown whitespace and Unicode normalizer.
        Default: $true. Set to $false for a pre-postprocessor forensic view;
        upstream parsing and rendering still apply.
    .PARAMETER OutputEncoding
        Markdown file encoding. Utf8 (default) is BOM-less. Utf16LE writes an
        FF FE BOM and preserves the rendered .NET UTF-16 code units verbatim.
        This parameter has no effect when OutputPath is omitted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExchangesJsonlPath,

        [string]$OutputPath,

        [ValidateSet('Diarized', 'Dialogue', 'Structural', 'House')]
        [string]$Format = 'Structural',

        [ValidateSet('thinking', 'commentary', 'tool-calls', 'tool-results',
            'subagents', 'synthetic', 'timestamps', 'session-markers',
            'exchange-markers')]
        [string[]]$Exclude = @(
            'thinking', 'commentary', 'tool-calls', 'tool-results',
            'subagents', 'synthetic', 'timestamps', 'session-markers',
            'exchange-markers'),

        [AllowNull()]
        [Nullable[int]]$MaxToolInputLength = 500,

        [bool]$NormalizeWhitespace = $true,

        [ValidateSet('Utf8', 'Utf16LE')]
        [string]$OutputEncoding = 'Utf8'
    )

    if (-not [System.IO.File]::Exists($ExchangesJsonlPath))
    {
        throw "Codex exchanges JSONL not found: $ExchangesJsonlPath"
    }

    $excludeSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$Exclude, [StringComparer]::OrdinalIgnoreCase)
    $models = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $doc = [System.Text.StringBuilder]::new()
    $threadId = $null
    $userLabel = $null
    $exchangeCount = 0
    $firstExchange = $true

    foreach ($line in [System.IO.File]::ReadLines($ExchangesJsonlPath))
    {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $exchange = $line | ConvertFrom-Json -Depth 100
        if (-not $threadId) { $threadId = [string]$exchange._thread_id }
        if (-not $userLabel) { $userLabel = [string]$exchange._user_label }
        if ($exchange._model) { [void]$models.Add([string]$exchange._model) }

        $promptText = $null
        $internal = [System.Text.StringBuilder]::new()
        $commentary = [System.Text.StringBuilder]::new()
        $finalResponse = [System.Text.StringBuilder]::new()
        $agentTurns = [System.Collections.Generic.List[object]]::new()

        foreach ($record in @($exchange.records))
        {
            switch ([string]$record._type)
            {
                'prompt'
                {
                    if (-not [string]::IsNullOrWhiteSpace([string]$record.text))
                    {
                        $promptText = ([string]$record.text).TrimEnd()
                    }
                }
                'thinking'
                {
                    if (-not $excludeSet.Contains('thinking') -and $record.text)
                    {
                        if ($internal.Length -gt 0) { [void]$internal.Append("`n`n") }
                        $block = "**[thinking]**`n$(([string]$record.text).TrimEnd())"
                        [void]$internal.Append((script:Quote-CodexMarkdownBlock $block))
                    }
                }
                'response'
                {
                    $text = ([string]$record.text).TrimEnd()
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }
                    if ([string]$record.phase -eq 'commentary')
                    {
                        if (-not $excludeSet.Contains('commentary'))
                        {
                            if ($commentary.Length -gt 0) { [void]$commentary.Append("`n`n") }
                            if ($Format -eq 'House')
                            {
                                $block = "**[commentary]**`n$text"
                                [void]$commentary.Append((script:Quote-CodexMarkdownBlock $block))
                            }
                            else { [void]$commentary.Append($text) }
                        }
                    }
                    else
                    {
                        if ($finalResponse.Length -gt 0) { [void]$finalResponse.Append("`n`n") }
                        [void]$finalResponse.Append($text)
                    }
                }
                'tool_call'
                {
                    if (-not $excludeSet.Contains('tool-calls'))
                    {
                        $toolMd = script:Get-CodexToolCallMarkdown `
                            -Record $record `
                            -ExcludeSet $excludeSet `
                            -MaxToolInputLength $MaxToolInputLength `
                            -Format $Format
                        if ($internal.Length -gt 0) { [void]$internal.Append("`n`n") }
                        [void]$internal.Append($toolMd)
                    }
                }
                'subagent'
                {
                    if (-not $excludeSet.Contains('subagents'))
                    {
                        [void]$agentTurns.Add($record)
                    }
                }
            }
        }

        $internalText = $internal.ToString().Trim()
        $commentaryText = $commentary.ToString().Trim()
        $finalText = $finalResponse.ToString().Trim()
        $assistant = [System.Text.StringBuilder]::new()
        foreach ($piece in @($internalText, $commentaryText, $finalText))
        {
            if (-not [string]::IsNullOrWhiteSpace($piece))
            {
                if ($assistant.Length -gt 0) { [void]$assistant.Append("`n`n") }
                [void]$assistant.Append($piece)
            }
        }
        $assistantText = $assistant.ToString().Trim()

        if ($null -eq $promptText -and
            $assistantText.Length -eq 0 -and
            $agentTurns.Count -eq 0)
        {
            continue
        }

        $exchangeCount++
        if (-not $excludeSet.Contains('exchange-markers') -and $exchange._xid)
        {
            [void]$doc.Append("<!-- xid: $($exchange._xid) -->`n`n")
        }

        switch ($Format)
        {
            'Diarized'
            {
                if ($promptText)
                {
                    $label = if ($userLabel) { $userLabel } else { 'Human' }
                    $speaker = if (-not $excludeSet.Contains('timestamps') -and
                        $exchange._exchange_start)
                    {
                        "**$label** · $($exchange._exchange_start)"
                    }
                    else { "**$label**" }
                    [void]$doc.Append("---`n`n$speaker`n`n$promptText`n`n")
                }
                if ($assistantText)
                {
                    [void]$doc.Append("---`n`n**Codex**`n`n$assistantText`n`n")
                }
            }
            'Dialogue'
            {
                if ($promptText)
                {
                    $label = if ($userLabel) { $userLabel } else { 'User' }
                    [void]$doc.Append("---`n`n${label}:`n`n$promptText`n`n")
                }
                if ($assistantText)
                {
                    [void]$doc.Append("---`n`nCodex:`n`n$assistantText`n`n")
                }
            }
            'Structural'
            {
                if ($promptText)
                {
                    if (-not $firstExchange) { [void]$doc.Append("---`n`n") }
                    [void]$doc.Append("# $promptText`n`n")
                }
                if ($assistantText) { [void]$doc.Append("$assistantText`n`n") }
            }
            'House'
            {
                if ($promptText)
                {
                    if (-not $firstExchange) { [void]$doc.Append("---`n`n") }
                    [void]$doc.Append("# $promptText`n`n")
                }
                if ($internalText) { [void]$doc.Append("$internalText`n`n") }
                if ($commentaryText) { [void]$doc.Append("$commentaryText`n`n") }
                if ($finalText)
                {
                    [void]$doc.Append("**Final response**`n`n$finalText`n`n")
                }
            }
        }

        foreach ($agent in $agentTurns)
        {
            $details = @(
                [string]$agent._agenttype,
                [string]$agent._agentdesc,
                [string]$agent._agentid
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            [void]$doc.Append('*Agent activity')
            if ($details.Count -gt 0) { [void]$doc.Append(" ($($details -join ' · '))") }
            [void]$doc.Append("*`n`n")
        }

        $firstExchange = $false
    }

    $frontmatter = script:Get-CodexMarkdownFrontmatter `
        -Format $Format `
        -Exclude $Exclude `
        -ThreadId $threadId `
        -Models $models `
        -ExchangeCount $exchangeCount `
        -UserLabel $userLabel
    $markdown = $frontmatter + $doc.ToString().TrimEnd() + "`n"
    if ($NormalizeWhitespace)
    {
        $markdown = Format-ChatExportMarkdown -Markdown $markdown
    }
    if ($OutputPath)
    {
        $outputDir = [System.IO.Path]::GetDirectoryName($OutputPath)
        if ($outputDir) { [void][System.IO.Directory]::CreateDirectory($outputDir) }
        Write-ChatExportText `
            -Path $OutputPath `
            -Text $markdown `
            -OutputEncoding $OutputEncoding
        return
    }
    return $markdown
}
