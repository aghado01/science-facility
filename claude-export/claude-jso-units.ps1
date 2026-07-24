# claude-jso-review.ps1 — Worker input renderer + worker helpers for the
# parallel summarization phase of the chat-review skill.
#
# Standalone — no dependencies on claude-jso-markdown-v2.ps1. Reads the
# exchanges JSONL produced by Export-ClaudeExchanges and writes one rendered
# `.input.md` per envelope into WorkerInputs/<runstamp>/. Worker subagents
# read those files, summarize, and call back into Write-ClaudeExchangeSummary
# to drop a `.summary.md` + `.sig` into WorkerOutputs/<runstamp>/.
#
# Usage:
#   . "D:\aghado01\utils\jso-jackson\claude-export\claude-jso-units.ps1"
#
#   # orchestrator (one call, renders every envelope):
#   $items = ConvertTo-ClaudeReviewWorkerInputs `
#       -ExchangesJsonlPath $exJsonl `
#       -WorkingDir         $workingDir `
#       -RunStamp           '20260426_143022'
#
#   # worker (envelope_id resolved by orchestrator from $items):
#   $env:CLAUDE_REVIEW_WORK_DIR   = $workingDir
#   $env:CLAUDE_REVIEW_RUN_STAMP  = '20260426_143022'
#   $w = Get-ClaudeReviewWorkerInput -EnvelopeId $items[0].EnvelopeId
#   # ... read $w.InputPath, summarize ...
#   Write-ClaudeExchangeSummary -EnvelopeId $w.EnvelopeId `
#       -Title 'Refactor batch dispatch' `
#       -Summary 'Batch now sends only leaf UUIDs; chain resolution moved to manifest sentinel walk.'
#
# FUNCTIONS
# ---------
#   ConvertTo-ClaudeReviewWorkerInputs   Render every envelope to its own input.md.
#   Get-ClaudeReviewWorkerInput          Worker-side: resolve paths for an envelope.
#   Write-ClaudeExchangeSummary          Worker-side: write success summary + sig.
#   Write-ClaudeExchangeSummaryError     Worker-side: write error sig only.
#
# FILESYSTEM LAYOUT (siblings to exchanges/ under {WorkingDir})
#   WorkerInputs/<runstamp>/<envelope_id>.input.md
#   WorkerOutputs/<runstamp>/<envelope_id>.summary.md
#   WorkerOutputs/<runstamp>/<envelope_id>.sig
#
# RENDER FORMAT (per input.md)
#   # Instructions
#   <instructions body>
#   ---
#   # Prompt
#   <prompt body — may contain ##+ headers from the user>
#
#   <response body — bare, may contain ##+ headers from the model>
#
#   With opt-in switches inserting in record order:
#     -IncludeThinking    ->  > blockquote
#     -IncludeTools       ->  fenced code blocks (input json + result text)
#     -IncludeSubagents   ->  <details><summary>...</summary> ... </details>
#
# WORKER-SIDE ENV VARS (set by orchestrator)
#   CLAUDE_REVIEW_WORK_DIR   absolute path of {WorkingDir}
#   CLAUDE_REVIEW_RUN_STAMP  the runstamp the orchestrator chose
# -----------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------
# Default summarization instructions — placeholder. Tighten as the spec
# firms up. Override per-call via -Instructions.
# -----------------------------------------------------------------------
$script:DefaultReviewInstructions = @'
You are summarizing a single exchange from a chat transcript.

Output two fields:
  - title:   3-6 word noun phrase capturing the topic of this exchange
  - summary: a few sentences. Aim for concise but thorough — keep
             load-bearing detail; cut filler.

Discipline: faithful narration only. Do not resolve cross-envelope
references; if the exchange refers to "the function we discussed earlier"
or similar, report it as-is rather than inferring what was meant.
'@


function ConvertTo-ClaudeReviewWorkerInputs
{
    <#
    .SYNOPSIS
        Render every envelope in an exchanges JSONL to its own .input.md file.
    .DESCRIPTION
        Writes one markdown file per envelope into
        {WorkingDir}/WorkerInputs/{RunStamp}/{envelope_id}.input.md.
        Default content is prompt + bare response only; opt-in switches add
        thinking, tool dialog, and subagent transcripts in record order.
        The corresponding output dir {WorkingDir}/WorkerOutputs/{RunStamp}/
        is created up front so workers can drop summary files into it.
    .PARAMETER ExchangesJsonlPath
        Path to the exchanges JSONL (one envelope per line).
    .PARAMETER WorkingDir
        Pipeline working directory. WorkerInputs/ and WorkerOutputs/ are
        created as siblings of exchanges/ under this path.
    .PARAMETER RunStamp
        Runstamp used to scope this dispatch. Defaults to current local
        time as yyyyMMdd_HHmmss.
    .PARAMETER Instructions
        Instructions block prepended to every input.md. Defaults to
        $script:DefaultReviewInstructions.
    .PARAMETER IncludeThinking
        Render thinking records as blockquotes in record order.
    .PARAMETER IncludeTools
        Render tool_call records as fenced code blocks (input + result)
        in record order. Tool input is truncated per -MaxToolInputLength.
    .PARAMETER IncludeSubagents
        Render subagent records as <details>/<summary> HTML blocks.
    .PARAMETER MaxToolInputLength
        Truncate tool input JSON at this many characters when -IncludeTools
        is set. Default 500. $null = no truncation.
    .PARAMETER Force
        Overwrite an existing WorkerInputs/{RunStamp}/ dir.
    .OUTPUTS
        PSCustomObject[] — one per envelope:
            { EnvelopeId, Xidx, ThreadId, InputPath, OutputPath, SigPath, Truncated[] }
        Truncated is a list of @{ Field; Original; Limit } — empty when
        nothing was trimmed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExchangesJsonlPath,

        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [string]$RunStamp,

        [string]$Instructions = $script:DefaultReviewInstructions,

        [switch]$IncludeThinking,
        [switch]$IncludeTools,
        [switch]$IncludeSubagents,

        [AllowNull()]
        [Nullable[int]]$MaxToolInputLength = 500,

        [switch]$Force
    )

    if (-not [System.IO.File]::Exists($ExchangesJsonlPath))
    {
        throw "Exchanges JSONL not found: $ExchangesJsonlPath"
    }

    if (-not $RunStamp)
    {
        $RunStamp = [DateTime]::Now.ToString('yyyyMMdd_HHmmss')
    }

    $inputsDir  = [System.IO.Path]::Combine($WorkingDir, 'WorkerInputs',  $RunStamp)
    $outputsDir = [System.IO.Path]::Combine($WorkingDir, 'WorkerOutputs', $RunStamp)

    if ([System.IO.Directory]::Exists($inputsDir) -and -not $Force)
    {
        throw "WorkerInputs run dir already exists (use -Force to overwrite): $inputsDir"
    }

    [void][System.IO.Directory]::CreateDirectory($inputsDir)
    [void][System.IO.Directory]::CreateDirectory($outputsDir)

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $results  = [System.Collections.Generic.List[object]]::new()

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

            $xch = [System.Text.Json.JsonSerializer]::Deserialize(
                $trimmed, [System.Text.Json.JsonElement])

            $xid      = $null
            $xidx     = 0
            $threadId = $null
            try { $xid      = $xch.GetProperty('_xid').GetString() }      catch { throw $_ }
            try { $xidx     = $xch.GetProperty('_xidx').GetInt32() }      catch { throw $_ }
            try { $threadId = $xch.GetProperty('_thread_id').GetString() } catch { throw $_ }

            $recordsEl = $xch.GetProperty('records')
            if ($recordsEl.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) { continue }

            $renderResult = script:Get-ReviewEnvelopeBody `
                -RecordsEl         $recordsEl `
                -EnvelopeId        $xid `
                -IncludeThinking:  $IncludeThinking `
                -IncludeTools:     $IncludeTools `
                -IncludeSubagents: $IncludeSubagents `
                -MaxToolInputLength $MaxToolInputLength

            $body = $renderResult.Body
            $truncations = $renderResult.Truncations

            $inputPath  = [System.IO.Path]::Combine($inputsDir,  "$xid.input.md")
            $outputPath = [System.IO.Path]::Combine($outputsDir, "$xid.summary.md")
            $sigPath    = [System.IO.Path]::Combine($outputsDir, "$xid.sig")

            $doc = [System.Text.StringBuilder]::new()
            [void]$doc.Append("# Instructions`n`n")
            [void]$doc.Append($Instructions.TrimEnd())
            [void]$doc.Append("`n`n---`n`n")
            [void]$doc.Append($body.TrimEnd())
            [void]$doc.Append("`n")

            [System.IO.File]::WriteAllText($inputPath, $doc.ToString(), $encoding)

            foreach ($t in $truncations)
            {
                Write-Warning ("[review-render] truncated {0} on {1}: {2} -> {3}" -f
                    $t.Field, $xid, $t.Original, $t.Limit)
            }

            $results.Add([PSCustomObject]@{
                    EnvelopeId  = $xid
                    Xidx        = $xidx
                    ThreadId    = $threadId
                    InputPath   = $inputPath
                    OutputPath  = $outputPath
                    SigPath     = $sigPath
                    Truncated   = $truncations.ToArray()
                })
        }
    }
    finally
    {
        $sr.Dispose()
        $fs.Dispose()
    }

    return $results.ToArray()
}


function Get-ClaudeReviewWorkerInput
{
    <#
    .SYNOPSIS
        Worker-side: resolve the input/output/sig paths for an envelope.
    .DESCRIPTION
        Reads $env:CLAUDE_REVIEW_WORK_DIR and $env:CLAUDE_REVIEW_RUN_STAMP
        and returns the input.md path the worker should read along with the
        output paths the corresponding write helpers will use. No content is
        loaded — workers read InputPath directly so the read appears in their
        own transcript.
    .PARAMETER EnvelopeId
        The envelope id (e.g. `{threadId}-{xidx:D4}`) the orchestrator handed
        to this worker.
    .OUTPUTS
        PSCustomObject { EnvelopeId, InputPath, OutputPath, SigPath }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EnvelopeId
    )

    $ctx = script:Get-ReviewWorkerContext
    $inputPath  = [System.IO.Path]::Combine($ctx.InputsDir,  "$EnvelopeId.input.md")
    $outputPath = [System.IO.Path]::Combine($ctx.OutputsDir, "$EnvelopeId.summary.md")
    $sigPath    = [System.IO.Path]::Combine($ctx.OutputsDir, "$EnvelopeId.sig")

    if (-not [System.IO.File]::Exists($inputPath))
    {
        throw "Worker input not found for envelope '$EnvelopeId': $inputPath"
    }

    return [PSCustomObject]@{
        EnvelopeId = $EnvelopeId
        InputPath  = $inputPath
        OutputPath = $outputPath
        SigPath    = $sigPath
    }
}


function Write-ClaudeExchangeSummary
{
    <#
    .SYNOPSIS
        Worker-side: write the success-path summary + sig for an envelope.
    .DESCRIPTION
        Writes both {envelope_id}.summary.md (markdown body + YAML
        frontmatter) and {envelope_id}.sig (JSON, status:ok) into
        WorkerOutputs/<runstamp>/. Warns (but does not throw) on
        suspiciously long titles or summaries — the spec is intentionally
        loose at this stage.
    .PARAMETER EnvelopeId
        Envelope id this summary covers.
    .PARAMETER Title
        Short title (3-6 word noun phrase per default instructions).
    .PARAMETER Summary
        Prose summary body (markdown, plain text usually fine).
    .PARAMETER Worker
        Optional caller identifier for the .sig and frontmatter (e.g.
        'wave_3_slot_7'). Defaults to 'unknown'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EnvelopeId,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Summary,

        [string]$Worker = 'unknown'
    )

    $ctx = script:Get-ReviewWorkerContext

    if ($Title.Length -gt 200)
    {
        Write-Warning "[review-summary] title >200 chars on ${EnvelopeId}: $($Title.Length)"
    }
    if ($Summary.Length -gt 4000)
    {
        Write-Warning "[review-summary] summary >4000 chars on ${EnvelopeId}: $($Summary.Length)"
    }

    $threadId = script:Get-ThreadIdFromEnvelopeId $EnvelopeId
    $xidx     = script:Get-XidxFromEnvelopeId     $EnvelopeId
    $now      = [datetime]::UtcNow.ToString('o')

    $fm = [System.Text.StringBuilder]::new()
    [void]$fm.Append("---`n")
    [void]$fm.Append("envelope_id: $EnvelopeId`n")
    [void]$fm.Append("thread_id: $threadId`n")
    [void]$fm.Append("xidx: $xidx`n")
    [void]$fm.Append("title: $(script:Format-YamlScalar $Title)`n")
    [void]$fm.Append("generated_at: $now`n")
    [void]$fm.Append("worker: $(script:Format-YamlScalar $Worker)`n")
    [void]$fm.Append("---`n`n")
    [void]$fm.Append($Summary.TrimEnd())
    [void]$fm.Append("`n")

    $outputPath = [System.IO.Path]::Combine($ctx.OutputsDir, "$EnvelopeId.summary.md")
    $sigPath    = [System.IO.Path]::Combine($ctx.OutputsDir, "$EnvelopeId.sig")

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($outputPath, $fm.ToString(), $encoding)

    $sig = [ordered]@{
        status = 'ok'
        at     = $now
        worker = $Worker
    }
    [System.IO.File]::WriteAllText(
        $sigPath,
        ($sig | ConvertTo-Json -Compress -Depth 5),
        $encoding)
}


function Write-ClaudeExchangeSummaryError
{
    <#
    .SYNOPSIS
        Worker-side: write the error-path sig for an envelope (no summary).
    .DESCRIPTION
        Writes only {envelope_id}.sig with status:err and a reason. Used
        when the worker can't produce a summary (rendering bad, model
        refused, exception, etc.) so the orchestrator can detect partial
        completion by scanning .sig files.
    .PARAMETER EnvelopeId
        Envelope id this error applies to.
    .PARAMETER Reason
        Short human-readable reason (one line).
    .PARAMETER Worker
        Optional caller identifier. Defaults to 'unknown'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EnvelopeId,

        [Parameter(Mandatory)]
        [string]$Reason,

        [string]$Worker = 'unknown'
    )

    $ctx = script:Get-ReviewWorkerContext
    $sigPath = [System.IO.Path]::Combine($ctx.OutputsDir, "$EnvelopeId.sig")

    $sig = [ordered]@{
        status = 'err'
        at     = [datetime]::UtcNow.ToString('o')
        worker = $Worker
        error  = $Reason
    }
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText(
        $sigPath,
        ($sig | ConvertTo-Json -Compress -Depth 5),
        $encoding)
}


# -----------------------------------------------------------------------
#region Private helpers
# -----------------------------------------------------------------------

function script:Get-ReviewWorkerContext
{
    $workDir  = $env:CLAUDE_REVIEW_WORK_DIR
    $runStamp = $env:CLAUDE_REVIEW_RUN_STAMP

    if (-not $workDir)
    {
        throw "CLAUDE_REVIEW_WORK_DIR env var not set — orchestrator must set it before dispatching workers."
    }
    if (-not $runStamp)
    {
        throw "CLAUDE_REVIEW_RUN_STAMP env var not set — orchestrator must set it before dispatching workers."
    }

    $inputsDir  = [System.IO.Path]::Combine($workDir, 'WorkerInputs',  $runStamp)
    $outputsDir = [System.IO.Path]::Combine($workDir, 'WorkerOutputs', $runStamp)

    if (-not [System.IO.Directory]::Exists($outputsDir))
    {
        [void][System.IO.Directory]::CreateDirectory($outputsDir)
    }

    return [PSCustomObject]@{
        WorkDir    = $workDir
        RunStamp   = $runStamp
        InputsDir  = $inputsDir
        OutputsDir = $outputsDir
    }
}


function script:Get-ThreadIdFromEnvelopeId
{
    param([string]$EnvelopeId)
    # envelope_id pattern: {uuid}-{xidx:D4}
    if ($EnvelopeId -match '^(?<tid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})-\d{4}$')
    {
        return $Matches['tid']
    }
    throw "Cannot parse thread_id from envelope_id: $EnvelopeId"
}


function script:Get-XidxFromEnvelopeId
{
    param([string]$EnvelopeId)
    if ($EnvelopeId -match '-(?<x>\d{4})$')
    {
        return [int]$Matches['x']
    }
    throw "Cannot parse xidx from envelope_id: $EnvelopeId"
}


function script:Format-YamlScalar
{
    param([string]$Value)
    # Quote if the value contains anything that would confuse a YAML 1.2
    # parser used as an unquoted scalar — colons, leading/trailing space,
    # leading hash/dash, control chars. Keep it simple: quote everything
    # that's not "obviously safe ASCII text".
    if ($null -eq $Value) { return '""' }
    if ($Value.Length -eq 0) { return '""' }

    $needsQuote =
        $Value.Contains(':') -or
        $Value.Contains('"') -or
        $Value.Contains("'") -or
        $Value.Contains('#') -or
        $Value.Contains("`n") -or
        $Value.Contains("`r") -or
        $Value.StartsWith(' ') -or
        $Value.EndsWith(' ')   -or
        $Value -match '^[\-\?\&\*\!\|\>\%\@\`]'

    if (-not $needsQuote) { return $Value }

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r')
    return '"' + $escaped + '"'
}


function script:Get-ReviewEnvelopeBody
{
    param(
        [System.Text.Json.JsonElement]$RecordsEl,
        [string]$EnvelopeId,
        [switch]$IncludeThinking,
        [switch]$IncludeTools,
        [switch]$IncludeSubagents,
        [AllowNull()]
        [Nullable[int]]$MaxToolInputLength
    )

    $sb = [System.Text.StringBuilder]::new()
    $truncations = [System.Collections.Generic.List[hashtable]]::new()
    $promptEmitted = $false

    foreach ($rec in $RecordsEl.EnumerateArray())
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
                    if (-not $promptEmitted)
                    {
                        [void]$sb.Append("# Prompt`n`n")
                        [void]$sb.Append($text.TrimEnd())
                        [void]$sb.Append("`n`n")
                        $promptEmitted = $true
                    }
                    else
                    {
                        # Multi-prompt envelopes: bare consecutive blocks
                        [void]$sb.Append($text.TrimEnd())
                        [void]$sb.Append("`n`n")
                    }
                }
            }

            'response'
            {
                $text = $null
                try { $text = $rec.GetProperty('text').GetString() } catch {}
                if ($text -and $text.Trim().Length -gt 0)
                {
                    [void]$sb.Append($text.TrimEnd())
                    [void]$sb.Append("`n`n")
                }
            }

            'thinking'
            {
                if (-not $IncludeThinking) { continue }
                $text = $null
                try { $text = $rec.GetProperty('text').GetString() } catch {}
                if ($text -and $text.Trim().Length -gt 0)
                {
                    [void]$sb.Append("> **[thinking]**`n>`n")
                    foreach ($ln in ($text.TrimEnd() -split "`n"))
                    {
                        [void]$sb.Append('> ' + $ln.TrimEnd() + "`n")
                    }
                    [void]$sb.Append("`n")
                }
            }

            'tool_call'
            {
                if (-not $IncludeTools) { continue }
                $toolMd = script:Get-ReviewToolCallMarkdown `
                    -Rec                $rec `
                    -EnvelopeId         $EnvelopeId `
                    -MaxToolInputLength $MaxToolInputLength `
                    -Truncations        $truncations
                if ($toolMd)
                {
                    [void]$sb.Append($toolMd)
                    [void]$sb.Append("`n`n")
                }
            }

            'subagent'
            {
                if (-not $IncludeSubagents) { continue }
                $agentType = $null
                $agentDesc = $null
                $text = $null
                try { $agentType = $rec.GetProperty('_agenttype').GetString() } catch {}
                try { $agentDesc = $rec.GetProperty('_agentdesc').GetString() } catch {}
                try { $text      = $rec.GetProperty('text').GetString() }       catch {}

                if ($text -and $text.Trim().Length -gt 0)
                {
                    $labelParts = [System.Collections.Generic.List[string]]::new()
                    $labelParts.Add('Subagent')
                    if ($agentType) { $labelParts.Add($agentType) }
                    if ($agentDesc) { $labelParts.Add('"' + $agentDesc + '"') }
                    $label = $labelParts -join ' · '

                    [void]$sb.Append("<details><summary>$label</summary>`n`n")
                    [void]$sb.Append($text.TrimEnd())
                    [void]$sb.Append("`n`n</details>`n`n")
                }
            }
        }
    }

    return [PSCustomObject]@{
        Body         = $sb.ToString()
        Truncations  = $truncations
    }
}


function script:Get-ReviewToolCallMarkdown
{
    param(
        [System.Text.Json.JsonElement]$Rec,
        [string]$EnvelopeId,
        [Nullable[int]]$MaxToolInputLength,
        [System.Collections.Generic.List[hashtable]]$Truncations
    )

    $toolName  = $null
    $toolUseId = $null
    try { $toolName  = $Rec.GetProperty('tool_name').GetString() }  catch {}
    try { $toolUseId = $Rec.GetProperty('tool_use_id').GetString() } catch {}

    $inputEl = [System.Text.Json.JsonElement]::new()
    try { $inputEl = $Rec.GetProperty('input') } catch {}

    $inputJson = ''
    if ($inputEl.ValueKind -notin @(
            [System.Text.Json.JsonValueKind]::Undefined,
            [System.Text.Json.JsonValueKind]::Null))
    {
        $inputJson = [System.Text.Json.JsonSerializer]::Serialize(
            $inputEl, [System.Text.Json.JsonElement])
        if ($null -ne $MaxToolInputLength -and $inputJson.Length -gt $MaxToolInputLength)
        {
            $original = $inputJson.Length
            $inputJson = $inputJson.Substring(0, $MaxToolInputLength) + ' ... [truncated]'
            [void]$Truncations.Add(@{
                    Field    = "tool_call.input ($toolName)"
                    Original = $original
                    Limit    = $MaxToolInputLength
                })
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("**[tool: $toolName]**`n")
    [void]$sb.Append('```json' + "`n")
    [void]$sb.Append("$inputJson`n")
    [void]$sb.Append('```')

    $responseEl = [System.Text.Json.JsonElement]::new()
    try { $responseEl = $Rec.GetProperty('response') } catch {}
    if ($responseEl.ValueKind -in @(
            [System.Text.Json.JsonValueKind]::Undefined,
            [System.Text.Json.JsonValueKind]::Null))
    {
        return $sb.ToString()
    }

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

    return $sb.ToString()
}

#endregion
