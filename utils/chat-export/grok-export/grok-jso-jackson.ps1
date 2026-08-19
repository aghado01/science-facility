# grok-jso-jackson.ps1 — Grok session resolve and chat_history → exchange IR
#
# Canonical content lane: ~/.grok/sessions/<encoded-cwd>/<session-id>/chat_history.jsonl
# updates.jsonl is the ACP UI stream and is not duplicated here.
# Snapshot, exchange write, and Markdown render are in ../shared.

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\shared\jsonl.ps1"

function Get-GrokHome
{
    [CmdletBinding()]
    param([string]$GrokHome)

    if ([string]::IsNullOrWhiteSpace($GrokHome))
    {
        $GrokHome = $env:GROK_HOME
    }
    if ([string]::IsNullOrWhiteSpace($GrokHome))
    {
        $profileRoot = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::UserProfile)
        $GrokHome = [System.IO.Path]::Combine($profileRoot, '.grok')
    }

    return [System.IO.Path]::GetFullPath($GrokHome)
}

function script:Get-GrokUserText
{
    param([object]$Record)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($block in @($Record.content))
    {
        if ($null -eq $block) { continue }
        if ($block -is [string])
        {
            if (-not [string]::IsNullOrWhiteSpace($block))
            {
                [void]$parts.Add($block.TrimEnd())
            }
            continue
        }

        $text = [string]$block.text
        if (-not [string]::IsNullOrWhiteSpace($text))
        {
            [void]$parts.Add($text.TrimEnd())
        }
    }

    $joined = $parts -join "`n`n"
    $query = [regex]::Match($joined, '(?s)<user_query>\s*(.*?)\s*</user_query>')
    if ($query.Success)
    {
        return $query.Groups[1].Value.TrimEnd()
    }
    return $joined
}

function script:Get-GrokReasoningText
{
    param([object]$Record)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($summary in @($Record.summary))
    {
        if ($null -eq $summary) { continue }
        if ($summary -is [string])
        {
            if (-not [string]::IsNullOrWhiteSpace($summary))
            {
                [void]$parts.Add($summary.TrimEnd())
            }
            continue
        }
        $text = [string]$summary.text
        if (-not [string]::IsNullOrWhiteSpace($text))
        {
            [void]$parts.Add($text.TrimEnd())
        }
    }
    return ($parts -join "`n`n")
}

function script:Test-GrokUserPrompt
{
    param([object]$Record)

    $names = @($Record.PSObject.Properties.Name)
    if ($names -contains 'prompt_index' -and $null -ne $Record.prompt_index)
    {
        return $true
    }

    $text = script:Get-GrokUserText $Record
    return $text.Contains('<user_query>')
}

function script:Get-GrokSummary
{
    param([string]$SessionDir)

    $path = [System.IO.Path]::Combine($SessionDir, 'summary.json')
    if (-not [System.IO.File]::Exists($path)) { return $null }
    try
    {
        return (Get-Content -LiteralPath $path -Raw -Encoding utf8) |
            ConvertFrom-Json -Depth 20
    }
    catch { return $null }
}

function Resolve-GrokSessionPath
{
    <#
    .SYNOPSIS
        Locate a Grok session directory from its session id.
    .DESCRIPTION
        Searches $GROK_HOME/sessions for a directory named SessionId that
        contains chat_history.jsonl. Zero or multiple hits throw; there is
        no newest-mtime fallback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [string]$GrokHome
    )

    $uuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($SessionId -notmatch $uuidPattern)
    {
        throw "Malformed Grok session id: '$SessionId'. Expected an 8-4-4-4-12 UUID."
    }

    $resolvedHome = Get-GrokHome -GrokHome $GrokHome
    $sessionsDir = [System.IO.Path]::Combine($resolvedHome, 'sessions')
    if (-not [System.IO.Directory]::Exists($sessionsDir))
    {
        throw "Grok sessions directory not found: $sessionsDir"
    }

    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($path in [System.IO.Directory]::GetFiles(
            $sessionsDir, 'chat_history.jsonl', [System.IO.SearchOption]::AllDirectories))
    {
        $dir = [System.IO.Path]::GetDirectoryName($path)
        if ([string]::Equals(
                [System.IO.Path]::GetFileName($dir),
                $SessionId,
                [StringComparison]::OrdinalIgnoreCase))
        {
            [void]$hits.Add($dir)
        }
    }

    if ($hits.Count -eq 0)
    {
        throw "No Grok session found for $SessionId under $sessionsDir."
    }
    if ($hits.Count -gt 1)
    {
        throw ("Ambiguous Grok session $SessionId; found $($hits.Count) directories:`n  " +
            ($hits -join "`n  "))
    }

    $sessionDir = $hits[0]
    $historyPath = [System.IO.Path]::Combine($sessionDir, 'chat_history.jsonl')
    $summary = script:Get-GrokSummary -SessionDir $sessionDir
    $cwd = $null
    $model = $null
    $effort = $null
    $title = $null
    $createdAt = $null
    if ($null -ne $summary)
    {
        if ($summary.info.cwd) { $cwd = [string]$summary.info.cwd }
        if ($summary.current_model_id) { $model = [string]$summary.current_model_id }
        if ($summary.reasoning_effort) { $effort = [string]$summary.reasoning_effort }
        if ($summary.generated_title) { $title = [string]$summary.generated_title }
        elseif ($summary.session_summary) { $title = [string]$summary.session_summary }
        if ($summary.created_at) { $createdAt = [string]$summary.created_at }
    }

    return [pscustomobject]@{
        SessionId   = $SessionId
        SessionDir  = $sessionDir
        HistoryPath = $historyPath
        GrokHome    = $resolvedHome
        Cwd         = $cwd
        Model       = $model
        Effort      = $effort
        Title       = $title
        CreatedAt   = $createdAt
    }
}

function script:New-GrokToolCallAtomic
{
    param(
        [object]$Call,
        [string]$TurnId,
        [System.Collections.Generic.Dictionary[string, object]]$OutputMap
    )

    $callId = [string]$Call.id
    if ([string]::IsNullOrWhiteSpace($callId)) { $callId = [string]$Call.tool_call_id }

    $toolName = [string]$Call.name
    if ([string]::IsNullOrWhiteSpace($toolName)) { $toolName = [string]$Call.tool }

    $toolInput = $null
    if (@($Call.PSObject.Properties.Name) -contains 'arguments')
    {
        $toolInput = ConvertFrom-ChatJsonString $Call.arguments
    }
    elseif (@($Call.PSObject.Properties.Name) -contains 'input')
    {
        $toolInput = ConvertFrom-ChatJsonString $Call.input
    }

    $response = $null
    if ($callId -and $OutputMap.ContainsKey($callId))
    {
        $matched = $OutputMap[$callId]
        $response = [ordered]@{
            tool_use_id = $callId
            content     = $matched
        }
    }

    return [ordered]@{
        _type        = 'tool_call'
        _source_uuid = $callId
        _turn_id     = $TurnId
        tool_use_id  = $callId
        tool_name    = $toolName
        tool_kind    = [string]$Call.type
        input        = $toolInput
        response     = $response
    }
}

function Get-GrokExchanges
{
    <#
    .SYNOPSIS
        Normalize a chat_history snapshot into exchange-envelope objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotPath,

        [Parameter(Mandatory)]
        [string]$SessionId,

        [string]$UserLabel = 'Aipithicus',
        [string]$DefaultModel,
        [string]$DefaultEffort
    )

    if (-not [System.IO.File]::Exists($SnapshotPath))
    {
        throw "Snapshot not found: $SnapshotPath"
    }

    $outputMap = [System.Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal)

    foreach ($line in [System.IO.File]::ReadLines($SnapshotPath))
    {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json -Depth 100 } catch { continue }
        if ([string]$record.type -ne 'tool_result') { continue }
        $callId = [string]$record.tool_call_id
        if ([string]::IsNullOrWhiteSpace($callId)) { continue }
        $outputMap[$callId] = $record.content
    }

    $exchanges = [System.Collections.Generic.List[object]]::new()
    $pendingSynthetic = [System.Collections.Generic.List[object]]::new()
    $state = [pscustomobject]@{
        CurrentTurnId = $null
        CurrentModel  = $DefaultModel
        CurrentEffort = $DefaultEffort
        Current       = $null
    }

    $closeExchange = {
        if ($null -eq $state.Current) { return }
        $state.Current._turn_count = $state.Current.records.Count
        [void]$exchanges.Add($state.Current)
        $state.Current = $null
    }

    $addAtomic = {
        param([object]$Atomic)
        if ($null -eq $state.Current -or $null -eq $Atomic) { return }
        [void]$state.Current.records.Add($Atomic)
    }

    $sourceName = [System.IO.Path]::GetFileName($SnapshotPath)

    foreach ($line in [System.IO.File]::ReadLines($SnapshotPath))
    {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json -Depth 100 } catch { continue }
        $kind = [string]$record.type

        switch ($kind)
        {
            'system' { continue }
            'tool_result' { continue }
            'user'
            {
                $isPrompt = script:Test-GrokUserPrompt $Record
                $text = script:Get-GrokUserText $record
                if ([string]::IsNullOrWhiteSpace($text)) { continue }

                if ($isPrompt)
                {
                    & $closeExchange
                    $xidx = $exchanges.Count
                    $turnId = [string]$record.prompt_index
                    if ([string]::IsNullOrWhiteSpace($turnId)) { $turnId = "$xidx" }
                    $state.CurrentTurnId = $turnId
                    $records = [System.Collections.Generic.List[object]]::new()
                    [void]$records.Add([ordered]@{
                            _type        = 'prompt'
                            _source_uuid = $SessionId
                            _turn_id     = $turnId
                            text         = $text
                        })
                    foreach ($pending in $pendingSynthetic)
                    {
                        $pending._turn_id = $turnId
                        [void]$records.Add($pending)
                    }
                    $pendingSynthetic.Clear()
                    $state.Current = [ordered]@{
                        _xid            = "$SessionId-$($xidx.ToString('D4'))"
                        _xidx           = $xidx
                        _thread_id      = $SessionId
                        _turn_id        = $turnId
                        _source_thread  = $sourceName
                        _session_uuid   = $SessionId
                        _session_depth  = 0
                        _turn_count     = 1
                        _model          = $state.CurrentModel
                        _effort         = $state.CurrentEffort
                        _user_label     = $UserLabel
                        _status         = 'in_progress'
                        records         = $records
                    }
                }
                else
                {
                    $synthetic = [ordered]@{
                        _type        = 'synthetic'
                        _source_uuid = $SessionId
                        _turn_id     = $state.CurrentTurnId
                        reason       = [string]$record.synthetic_reason
                        text         = $text
                    }
                    if ($state.Current)
                    {
                        & $addAtomic $synthetic
                    }
                    else
                    {
                        [void]$pendingSynthetic.Add($synthetic)
                    }
                }
            }
            'reasoning'
            {
                $text = script:Get-GrokReasoningText $record
                if ($state.Current -and -not [string]::IsNullOrWhiteSpace($text))
                {
                    $id = [string]$record.id
                    & $addAtomic ([ordered]@{
                            _type        = 'thinking'
                            _source_uuid = if ($id) { $id } else { $SessionId }
                            _turn_id     = $state.CurrentTurnId
                            text         = $text
                        })
                }
            }
            'assistant'
            {
                if (-not $state.Current) { continue }

                if ($record.model_id)
                {
                    $state.CurrentModel = [string]$record.model_id
                    $state.Current._model = $state.CurrentModel
                }
                if ($record.reasoning_effort)
                {
                    $state.CurrentEffort = [string]$record.reasoning_effort
                    $state.Current._effort = $state.CurrentEffort
                }

                $content = [string]$record.content
                if (-not [string]::IsNullOrWhiteSpace($content))
                {
                    & $addAtomic ([ordered]@{
                            _type        = 'response'
                            _source_uuid = $SessionId
                            _turn_id     = $state.CurrentTurnId
                            phase        = 'final_answer'
                            text         = $content.TrimEnd()
                        })
                }

                foreach ($call in @($record.tool_calls))
                {
                    if ($null -eq $call) { continue }
                    $atomic = script:New-GrokToolCallAtomic `
                        -Call $call `
                        -TurnId $state.CurrentTurnId `
                        -OutputMap $outputMap
                    & $addAtomic $atomic

                    $toolName = [string]$atomic.tool_name
                    if ($toolName -in @('spawn_subagent', 'task'))
                    {
                        $desc = $null
                        if ($atomic.input -and
                            @($atomic.input.PSObject.Properties.Name) -contains 'description')
                        {
                            $desc = [string]$atomic.input.description
                        }
                        & $addAtomic ([ordered]@{
                                _type        = 'subagent'
                                _source_uuid = [string]$atomic.tool_use_id
                                _turn_id     = $state.CurrentTurnId
                                _agentid     = [string]$atomic.tool_use_id
                                _agenttype   = $toolName
                                _agentdesc   = $desc
                                text         = ''
                            })
                    }
                }
            }
        }
    }

    & $closeExchange
    if ($exchanges.Count -gt 0)
    {
        for ($i = 0; $i -lt ($exchanges.Count - 1); $i++)
        {
            $exchanges[$i]._status = 'completed'
        }
    }
    return $exchanges.ToArray()
}
