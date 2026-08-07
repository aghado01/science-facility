# claude-jso-markdown-v2.ps1 — Markdown renderer for Claude Code thread exports (exchanges layer)
#
# Standalone — no dependencies. Reads the exchanges JSONL produced by
# Export-ClaudeExchanges and renders a single markdown document.
#
# This is v2 of claude-jso-markdown.ps1. Same formats and output structure,
# but consumes the exchanges layer instead of the merged layer: content
# decomposition (thinking/response/tool_call/subagent) is already done and
# tool calls are pre-matched with their results.
#
# Usage:
#   . "D:\aghado01\science-facility\utils\chat-export\claude-export\claude-jso-markdown-v2.ps1"
#   ConvertTo-ClaudeMarkdownV2 -ExchangesJsonlPath $path -OutputPath thread.md
#   ConvertTo-ClaudeMarkdownV2 -ExchangesJsonlPath $path  # returns string
#
# FUNCTIONS
# ---------
#   ConvertTo-ClaudeMarkdownV2   Read exchanges JSONL, write or return markdown.
#
# FORMAT MODES
# ------------
#   Diarized   (default) Bold speaker headers (**Human**, **Claude**);
#              exchange separator ---
#   Dialogue   Simple colon labels (User:, Claude:, Agent:);
#              exchange separator ---
#   Structural Perplexity-style: human turns as # heading, Claude turns as
#              bare body; exchange separator --- before each human turn (except first)
#   House      H1 human prompts, quoted internal/tool blocks, explicit
#              final-response label; exchange separator --- before each
#              human turn (except first)
#
# COMPONENT TOKENS (for -Exclude)
# --------------------------------
#   thinking         assistant thinking blocks
#   tool-calls       tool_call records (entire call + result)
#   tool-results     response sub-object within tool_call (call shown, result hidden)
#   subagents        subagent atomic records
#   synthetic        no-op in v2 (synthetic records filtered at merge stage)
#   timestamps       per-exchange timestamp in speaker header
#   session-markers  <!-- session uuid depth:N --> HTML comments (Diarized/Dialogue only)
#   exchange-markers <!-- xid: ... --> HTML comments at exchange boundaries
#
# DEFAULT PROFILE: model-feeding
#   Excludes thinking, tool-calls, tool-results, subagents, synthetic, timestamps,
#   session-markers, and exchange-markers. Produces a clean Human / Claude dialogue.
#
# FRONTMATTER
#   All formats emit a YAML frontmatter block with: format, exported_at, exchanges,
#   sessions (short UUIDs), and the active exclude list.
#
# DIFFERENCES FROM V1
#   - Input is exchanges JSONL (exchanges/ layer) not merged JSONL (merged/ layer)
#   - Speaker labels never include model (not present in exchange envelopes)
#   - tool-results suppresses the result sub-object within a tool_call rather than
#     skipping a separate tool_result carrier record
#   - exchange-markers is a new exclude token with no v1 equivalent
#   - Frontmatter has exchanges: count instead of turns:, no models: section
# -----------------------------------------------------------------------

function ConvertTo-ClaudeMarkdownV2
{
    <#
    .SYNOPSIS
        Render an exchanges JSONL as a markdown document.
    .DESCRIPTION
        Reads a thread-*.jsonl produced by Export-ClaudeExchanges and renders it
        as a single markdown file. YAML frontmatter is always emitted. Format
        controls diarization style; -Exclude controls which content blocks appear.
    .PARAMETER ExchangesJsonlPath
        Path to a thread-*.jsonl produced by Export-ClaudeExchanges.
    .PARAMETER OutputPath
        Optional output .md file path. If omitted, returns the markdown string.
    .PARAMETER Format
        Structural (default) — Perplexity-style # heading prompts + bare responses.
        House                — H1 prompts + quoted internal/tool blocks + final response label.
        Diarized             — bold speaker headers with --- exchange separators.
        Dialogue             — simple colon labels, model attribution in frontmatter.
    .PARAMETER Exclude
        Array of component tokens to suppress. Defaults to the model-feeding
        profile (thinking, tool-calls, tool-results, subagents, synthetic,
        timestamps, session-markers, exchange-markers). Pass an empty array
        to include everything.
    .PARAMETER MaxToolInputLength
        Truncate tool_use input JSON at this many characters. $null = no truncation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExchangesJsonlPath,

        [string]$OutputPath,

        [ValidateSet('Diarized', 'Dialogue', 'Structural', 'House')]
        [string]$Format = 'Structural',

        [ValidateSet('thinking', 'tool-calls', 'tool-results', 'subagents',
            'synthetic', 'timestamps', 'session-markers', 'exchange-markers')]
        [string[]]$Exclude = @('thinking', 'tool-calls', 'tool-results',
            'subagents', 'synthetic', 'timestamps', 'session-markers', 'exchange-markers'),

        [AllowNull()]
        [Nullable[int]]$MaxToolInputLength = 500
    )

    if (-not [System.IO.File]::Exists($ExchangesJsonlPath))
    {
        throw "Exchanges JSONL not found: $ExchangesJsonlPath"
    }

    $ex = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$Exclude,
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $fmSessions = [System.Collections.Generic.HashSet[string]]::new()
    $fmModels = [System.Collections.Generic.HashSet[string]]::new()
    $fmUserLabel = $null
    $exchangeCount = 0

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $doc = [System.Text.StringBuilder]::new()
    [string]$lastSessionUuid = $null
    [int]$lastDepth = -1
    [bool]$firstExchange = $true

    $fs = [System.IO.FileStream]::new(
        $ExchangesJsonlPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $sr = [System.IO.StreamReader]::new($fs, $encoding)

    try
    {
        while ($null -ne ($rawLine = $sr.ReadLine()))
        {
            $trimmed = $rawLine.Trim()
            if ($trimmed.Length -eq 0) { continue }

            [System.Text.Json.JsonElement]$xch = [System.Text.Json.JsonElement]::new()
            try
            {
                $xch = [System.Text.Json.JsonSerializer]::Deserialize(
                    $trimmed, [System.Text.Json.JsonElement])
            }
            catch { throw $_ }

            # --- Exchange envelope fields ---
            $xid = $null
            $sessionUuid = $null
            [int]$sessionDepth = 0
            $exchangeStart = $null
            $xchModel = $null
            $xchUserLabel = $null

            try { $xid = $xch.GetProperty('_xid').GetString() }                  catch { throw $_ }
            try { $sessionUuid = $xch.GetProperty('_session_uuid').GetString() }  catch { throw $_ }
            try { $sessionDepth = $xch.GetProperty('_session_depth').GetInt32() } catch { throw $_ }
            try { $exchangeStart = $xch.GetProperty('_exchange_start').GetString() } catch { throw $_ }
            try { $xchModel = $xch.GetProperty('_model').GetString() }            catch {}
            try { $xchUserLabel = $xch.GetProperty('_user_label').GetString() }   catch {}

            # --- Decompose records into render buckets ---
            $recordsEl = [System.Text.Json.JsonElement]::new()
            try { $recordsEl = $xch.GetProperty('records') } catch { throw $_ }
            if ($recordsEl.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { continue }

            $promptText = $null
            $claudeInternalBlocks = [System.Text.StringBuilder]::new()
            $claudeResponseBlocks = [System.Text.StringBuilder]::new()
            # Each entry: [ordered]@{ label=string; content=string }
            $agentTurns = [System.Collections.Generic.List[hashtable]]::new()

            foreach ($rec in $recordsEl.EnumerateArray())
            {
                $recType = $null
                try { $recType = $rec.GetProperty('_type').GetString() } catch { continue }

                switch ($recType)
                {
                    'prompt'
                    {
                        $text = $null
                        try { $text = $rec.GetProperty('text').GetString() } catch {}
                        if ($text -and $text.Trim().Length -gt 0)
                        {
                            $promptText = $text.TrimEnd()
                        }
                    }

                    'thinking'
                    {
                        if (-not $ex.Contains('thinking'))
                        {
                            $text = $null
                            try { $text = $rec.GetProperty('text').GetString() } catch {}
                            if ($text -and $text.Trim().Length -gt 0)
                            {
                                if ($claudeInternalBlocks.Length -gt 0) { [void]$claudeInternalBlocks.Append("`n") }
                                [void]$claudeInternalBlocks.Append("> **[thinking]**`n")
                                [void]$claudeInternalBlocks.Append(">`n")
                                foreach ($tline in ($text.TrimEnd() -split "`n"))
                                {
                                    [void]$claudeInternalBlocks.Append('> ' + $tline.TrimEnd() + "`n")
                                }
                            }
                        }
                    }

                    'response'
                    {
                        $text = $null
                        try { $text = $rec.GetProperty('text').GetString() } catch {}
                        if ($text -and $text.Trim().Length -gt 0)
                        {
                            if ($claudeResponseBlocks.Length -gt 0) { [void]$claudeResponseBlocks.Append("`n") }
                            [void]$claudeResponseBlocks.Append($text.TrimEnd())
                        }
                    }

                    'tool_call'
                    {
                        if (-not $ex.Contains('tool-calls'))
                        {
                            $toolMd = script:Get-V2ToolCallMarkdown $rec $ex $MaxToolInputLength $Format
                            if ($toolMd)
                            {
                                if ($claudeInternalBlocks.Length -gt 0) { [void]$claudeInternalBlocks.Append("`n") }
                                [void]$claudeInternalBlocks.Append($toolMd)
                            }
                        }
                    }

                    'subagent'
                    {
                        if (-not $ex.Contains('subagents'))
                        {
                            $agentType = $null
                            $agentDesc = $null
                            $text = $null
                            try { $agentType = $rec.GetProperty('_agenttype').GetString() } catch {}
                            try { $agentDesc = $rec.GetProperty('_agentdesc').GetString() } catch {}
                            try { $text = $rec.GetProperty('text').GetString() } catch {}

                            if ($text -and $text.Trim().Length -gt 0)
                            {
                                $agentTurns.Add(@{
                                        AgentType = $agentType
                                        AgentDesc = $agentDesc
                                        Text      = $text.TrimEnd()
                                    })
                            }
                        }
                    }
                }
            }

            $claudeInternalContent = $claudeInternalBlocks.ToString().Trim()
            $claudeResponseContent = $claudeResponseBlocks.ToString().Trim()
            $claudeContent = [System.Text.StringBuilder]::new()
            if ($claudeInternalContent.Length -gt 0)
            {
                [void]$claudeContent.Append($claudeInternalContent)
            }
            if ($claudeResponseContent.Length -gt 0)
            {
                if ($claudeContent.Length -gt 0) { [void]$claudeContent.Append("`n`n") }
                [void]$claudeContent.Append($claudeResponseContent)
            }
            $claudeContentText = $claudeContent.ToString().Trim()

            # Skip exchange if nothing renderable survived exclusions
            if ($null -eq $promptText -and $claudeContentText.Length -eq 0 -and $agentTurns.Count -eq 0)
            { continue }

            $exchangeCount++
            if ($sessionUuid)  { [void]$fmSessions.Add($sessionUuid) }
            if ($xchModel)     { [void]$fmModels.Add($xchModel) }
            if ($xchUserLabel -and -not $fmUserLabel) { $fmUserLabel = $xchUserLabel }

            # --- Session marker on session/depth change (Diarized and Dialogue only) ---
            $sessionChanged = ($sessionDepth -ne $lastDepth) -or ($sessionUuid -ne $lastSessionUuid)
            if ($Format -ne 'Structural' -and
                -not $ex.Contains('session-markers') -and
                $sessionChanged -and $doc.Length -gt 0)
            {
                $shortId = if ($sessionUuid -and $sessionUuid.Length -ge 8)
                { $sessionUuid.Substring(0, 8) } else { $sessionUuid }
                [void]$doc.Append("`n<!-- session $shortId depth:$sessionDepth -->`n")
            }
            $lastSessionUuid = $sessionUuid
            $lastDepth = $sessionDepth

            # --- Exchange marker ---
            if (-not $ex.Contains('exchange-markers') -and $xid)
            {
                [void]$doc.Append("`n<!-- xid: $xid -->`n")
            }

            # --- Emit exchange ---
            switch ($Format)
            {
                'Diarized'
                {
                    if ($promptText)
                    {
                        $humanLabel = if ($xchUserLabel) { $xchUserLabel } else { 'Human' }
                        $speakerLine = if (-not $ex.Contains('timestamps') -and $exchangeStart)
                        { "**$humanLabel** · $exchangeStart" } else { "**$humanLabel**" }
                        [void]$doc.Append("---`n`n$speakerLine`n`n$promptText`n`n")
                    }

                    if ($claudeContentText.Length -gt 0)
                    {
                        [void]$doc.Append("---`n`n**Claude**`n`n$claudeContentText`n`n")
                    }

                    foreach ($turn in $agentTurns)
                    {
                        $label = script:Get-V2AgentDiarizedLabel $turn.AgentType $turn.AgentDesc
                        [void]$doc.Append("---`n`n**$label**`n`n$($turn.Text)`n`n")
                    }
                }

                'Dialogue'
                {
                    if ($promptText)
                    {
                        $humanLabel = if ($xchUserLabel) { $xchUserLabel } else { 'User' }
                        $speakerLine = if (-not $ex.Contains('timestamps') -and $exchangeStart)
                        { "$humanLabel [$exchangeStart]:" } else { "${humanLabel}:" }
                        [void]$doc.Append("---`n`n$speakerLine`n`n$promptText`n`n")
                    }

                    if ($claudeContentText.Length -gt 0)
                    {
                        [void]$doc.Append("---`n`nClaude:`n`n$claudeContentText`n`n")
                    }

                    foreach ($turn in $agentTurns)
                    {
                        $dialogueLabel = if ($turn.AgentType) { "Agent ($($turn.AgentType)):" } else { 'Agent:' }
                        [void]$doc.Append("---`n`n$dialogueLabel`n`n$($turn.Text)`n`n")
                    }
                }

                'Structural'
                {
                    if ($promptText)
                    {
                        if (-not $firstExchange) { [void]$doc.Append("---`n`n") }
                        [void]$doc.Append("# $promptText`n`n")
                    }

                    if ($claudeContentText.Length -gt 0)
                    {
                        [void]$doc.Append("$claudeContentText`n`n")
                    }

                    foreach ($turn in $agentTurns)
                    {
                        $attrParts = [System.Collections.Generic.List[string]]::new()
                        if ($turn.AgentType) { $attrParts.Add($turn.AgentType) }
                        if ($turn.AgentDesc) { $attrParts.Add('"' + $turn.AgentDesc + '"') }
                        $attrSuffix = if ($attrParts.Count -gt 0) { " ($($attrParts -join ' · '))" } else { '' }
                        [void]$doc.Append("*Agent$attrSuffix*`n`n$($turn.Text)`n`n")
                    }
                }

                'House'
                {
                    if ($promptText)
                    {
                        if (-not $firstExchange) { [void]$doc.Append("---`n`n") }
                        [void]$doc.Append("# $promptText`n`n")
                    }

                    if ($claudeInternalContent.Length -gt 0)
                    {
                        [void]$doc.Append("$claudeInternalContent`n`n")
                    }

                    foreach ($turn in $agentTurns)
                    {
                        $attrParts = [System.Collections.Generic.List[string]]::new()
                        if ($turn.AgentType) { $attrParts.Add($turn.AgentType) }
                        if ($turn.AgentDesc) { $attrParts.Add('"' + $turn.AgentDesc + '"') }
                        $attrSuffix = if ($attrParts.Count -gt 0) { " ($($attrParts -join ' · '))" } else { '' }
                        $agentBlock = "**[agent$attrSuffix]**`n$($turn.Text)"
                        [void]$doc.Append("$(script:Quote-V2MarkdownBlock $agentBlock)`n`n")
                    }

                    if ($claudeResponseContent.Length -gt 0)
                    {
                        [void]$doc.Append("**Final response**`n`n$claudeResponseContent`n`n")
                    }
                }
            }

            $firstExchange = $false
        }
    }
    finally
    {
        $sr.Dispose()
        $fs.Dispose()
    }

    $frontmatter = script:Get-V2Frontmatter $Format $Exclude $fmSessions $fmModels $exchangeCount $fmUserLabel
    $markdown = $frontmatter + $doc.ToString().TrimEnd() + "`n"

    if ($OutputPath)
    {
        $outDir = [System.IO.Path]::GetDirectoryName($OutputPath)
        if ($outDir -and -not [System.IO.Directory]::Exists($outDir))
        {
            [void][System.IO.Directory]::CreateDirectory($outDir)
        }
        [System.IO.File]::WriteAllText($OutputPath, $markdown, $encoding)
        return
    }
    return $markdown
}

# -----------------------------------------------------------------------
#region Private helpers
# -----------------------------------------------------------------------

function script:Get-V2ToolCallMarkdown
{
    param(
        [System.Text.Json.JsonElement]$rec,
        [System.Collections.Generic.HashSet[string]]$ex,
        [Nullable[int]]$maxToolLen,
        [string]$format
    )

    $toolName = $null
    $toolUseId = $null
    try { $toolName = $rec.GetProperty('tool_name').GetString() } catch {}
    try { $toolUseId = $rec.GetProperty('tool_use_id').GetString() } catch {}

    $inputEl = [System.Text.Json.JsonElement]::new()
    try { $inputEl = $rec.GetProperty('input') } catch {}

    $inputJson = ''
    if ($inputEl.ValueKind -notin @(
            [System.Text.Json.JsonValueKind]::Undefined,
            [System.Text.Json.JsonValueKind]::Null))
    {
        $inputJson = [System.Text.Json.JsonSerializer]::Serialize(
            $inputEl, [System.Text.Json.JsonElement])
        if ($null -ne $maxToolLen -and $inputJson.Length -gt $maxToolLen)
        {
            $inputJson = $inputJson.Substring(0, $maxToolLen) + ' ... [truncated]'
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("**[tool: $toolName]**`n")
    [void]$sb.Append('```json' + "`n")
    [void]$sb.Append("$inputJson`n")
    [void]$sb.Append('```')

    if (-not $ex.Contains('tool-results'))
    {
        $responseEl = [System.Text.Json.JsonElement]::new()
        try { $responseEl = $rec.GetProperty('response') } catch {}

        if ($responseEl.ValueKind -notin @(
                [System.Text.Json.JsonValueKind]::Undefined,
                [System.Text.Json.JsonValueKind]::Null))
        {
            $shortId = if ($toolUseId -and $toolUseId.Length -gt 16)
            { $toolUseId.Substring(0, 16) + '...' } else { $toolUseId }

            $resultText = ''
            $contentEl = [System.Text.Json.JsonElement]::new()
            try { $contentEl = $responseEl.GetProperty('content') } catch {}

            if ($contentEl.ValueKind -eq [System.Text.Json.JsonValueKind]::String)
            {
                $resultText = $contentEl.GetString()
            }
            elseif ($contentEl.ValueKind -eq [System.Text.Json.JsonValueKind]::Array)
            {
                $parts = [System.Collections.Generic.List[string]]::new()
                foreach ($rb in $contentEl.EnumerateArray())
                {
                    $rbType = $null
                    try { $rbType = $rb.GetProperty('type').GetString() } catch {}
                    if ($rbType -eq 'text')
                    {
                        $t = $null
                        try { $t = $rb.GetProperty('text').GetString() } catch {}
                        if ($t) { $parts.Add($t) }
                    }
                }
                $resultText = $parts -join "`n"
            }

            [void]$sb.Append("`n`n**[result: $shortId]**`n")
            [void]$sb.Append('```' + "`n")
            [void]$sb.Append("$($resultText.TrimEnd())`n")
            [void]$sb.Append('```')
        }
    }

    $markdown = $sb.ToString()
    if ($format -eq 'House')
    {
        return script:Quote-V2MarkdownBlock $markdown
    }

    return $markdown
}


function script:Quote-V2MarkdownBlock
{
    param(
        [string]$Text
    )

    if (-not $Text)
    {
        return ''
    }

    $sb = [System.Text.StringBuilder]::new()
    foreach ($line in ($Text.TrimEnd() -split "`n"))
    {
        if ($line.Length -eq 0)
        {
            [void]$sb.Append(">`n")
        }
        else
        {
            [void]$sb.Append('> ' + $line.TrimEnd() + "`n")
        }
    }

    return $sb.ToString().TrimEnd()
}


function script:Get-V2AgentDiarizedLabel
{
    param(
        [string]$agentType,
        [string]$agentDesc
    )
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('Agent')
    if ($agentType) { $parts.Add($agentType) }
    if ($agentDesc) { $parts.Add('"' + $agentDesc + '"') }
    return $parts -join ' · '
}


function script:Get-V2Frontmatter
{
    param(
        [string]$Format,
        [string[]]$Exclude,
        [System.Collections.Generic.HashSet[string]]$Sessions,
        [System.Collections.Generic.HashSet[string]]$Models,
        [int]$ExchangeCount,
        [string]$UserLabel
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("---`n")
    [void]$sb.Append("format: $Format`n")
    [void]$sb.Append("exported_at: $([datetime]::UtcNow.ToString('o'))`n")
    [void]$sb.Append("exchanges: $ExchangeCount`n")
    if ($UserLabel) { [void]$sb.Append("user_label: $UserLabel`n") }

    if ($Sessions.Count -gt 0)
    {
        [void]$sb.Append("sessions:`n")
        foreach ($s in ($Sessions | Sort-Object))
        {
            $short = if ($s.Length -ge 8) { $s.Substring(0, 8) } else { $s }
            [void]$sb.Append("  - $short`n")
        }
    }

    if ($Models.Count -gt 0)
    {
        [void]$sb.Append("models:`n")
        foreach ($m in ($Models | Sort-Object))
        {
            [void]$sb.Append("  - $m`n")
        }
    }

    if ($Exclude -and $Exclude.Count -gt 0)
    {
        [void]$sb.Append("exclude:`n")
        foreach ($e in $Exclude)
        {
            [void]$sb.Append("  - $e`n")
        }
    }

    [void]$sb.Append("---`n`n")
    return $sb.ToString()
}

#endregion
