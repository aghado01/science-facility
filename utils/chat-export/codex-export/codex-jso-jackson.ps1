# codex-jso-jackson.ps1 — Codex rollout ingest and exchange-envelope IR
#
# Minimal pipeline:
#   rollout JSONL -> stable snapshot -> exchange envelopes JSONL + .jidx
#
# This is a sibling implementation to claude-export. It reuses only the
# schema-agnostic jso-jackson primitives and does not load or modify the
# Claude-specific exporter.

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\..\jso-jackson\jso-jackson.ps1"

function Get-CodexHome
{
    [CmdletBinding()]
    param([string]$CodexHome)

    if ([string]::IsNullOrWhiteSpace($CodexHome))
    {
        $CodexHome = $env:CODEX_HOME
    }
    if ([string]::IsNullOrWhiteSpace($CodexHome))
    {
        $profileRoot = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::UserProfile)
        $CodexHome = [System.IO.Path]::Combine($profileRoot, '.codex')
    }

    return [System.IO.Path]::GetFullPath($CodexHome)
}

function script:ConvertTo-CodexIsoTimestamp
{
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime])
    {
        return $Value.ToUniversalTime().ToString('o')
    }
    if ($Value -is [datetimeoffset])
    {
        return $Value.ToUniversalTime().ToString('o')
    }

    $text = [string]$Value
    [datetimeoffset]$parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed))
    {
        return $parsed.ToUniversalTime().ToString('o')
    }
    return $text
}

function script:ConvertFrom-CodexJsonString
{
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -isnot [string]) { return $Value }
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }

    try { return ($Value | ConvertFrom-Json -Depth 100 -NoEnumerate) }
    catch { return $Value }
}

function script:Get-CodexMessageText
{
    param([object]$Payload)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($block in @($Payload.content))
    {
        if ($null -eq $block) { continue }
        switch ([string]$block.type)
        {
            { $_ -in @('input_text', 'output_text', 'text') }
            {
                if (-not [string]::IsNullOrWhiteSpace([string]$block.text))
                {
                    [void]$parts.Add(([string]$block.text).TrimEnd())
                }
            }
            { $_ -in @('local_image', 'localImage') }
            {
                if ($block.path) { [void]$parts.Add("[local image: $($block.path)]") }
            }
            { $_ -in @('input_image', 'image', 'image_url') }
            {
                [void]$parts.Add('[image]')
            }
        }
    }

    if ($parts.Count -eq 0 -and
        -not [string]::IsNullOrWhiteSpace([string]$Payload.message))
    {
        [void]$parts.Add(([string]$Payload.message).TrimEnd())
    }

    return ($parts -join "`n`n")
}

function script:Get-CodexReasoningText
{
    param([object]$Payload)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($summary in @($Payload.summary))
    {
        if ($null -ne $summary -and
            -not [string]::IsNullOrWhiteSpace([string]$summary.text))
        {
            [void]$parts.Add(([string]$summary.text).TrimEnd())
        }
    }
    foreach ($content in @($Payload.content))
    {
        if ($null -ne $content -and
            -not [string]::IsNullOrWhiteSpace([string]$content.text))
        {
            [void]$parts.Add(([string]$content.text).TrimEnd())
        }
    }
    return ($parts -join "`n`n")
}

function script:Get-CodexSessionMeta
{
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $fs = [System.IO.FileStream]::new(
        $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $sr = [System.IO.StreamReader]::new($fs, $encoding)
    try
    {
        while ($null -ne ($line = $sr.ReadLine()))
        {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $record = $line | ConvertFrom-Json -Depth 100
            if ($record.type -eq 'session_meta') { return $record.payload }
            break
        }
    }
    finally
    {
        $sr.Dispose()
        $fs.Dispose()
    }
    return $null
}

function Resolve-CodexThreadPath
{
    <#
    .SYNOPSIS
        Locate an active or archived Codex rollout from its thread id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ThreadId,

        [string]$CodexHome
    )

    $uuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if ($ThreadId -notmatch $uuidPattern)
    {
        throw "Malformed Codex thread id: '$ThreadId'. Expected an 8-4-4-4-12 UUID."
    }

    $resolvedHome = Get-CodexHome -CodexHome $CodexHome
    $sessionsDir = [System.IO.Path]::Combine($resolvedHome, 'sessions')
    $archivedDir = [System.IO.Path]::Combine($resolvedHome, 'archived_sessions')
    $pattern = "*-$ThreadId.jsonl"
    $hits = [System.Collections.Generic.List[string]]::new()

    if ([System.IO.Directory]::Exists($sessionsDir))
    {
        foreach ($path in [System.IO.Directory]::GetFiles(
                $sessionsDir, $pattern, [System.IO.SearchOption]::AllDirectories))
        {
            [void]$hits.Add($path)
        }
    }
    if ([System.IO.Directory]::Exists($archivedDir))
    {
        foreach ($path in [System.IO.Directory]::GetFiles(
                $archivedDir, $pattern, [System.IO.SearchOption]::TopDirectoryOnly))
        {
            [void]$hits.Add($path)
        }
    }

    if ($hits.Count -eq 0)
    {
        throw "No Codex rollout found for thread $ThreadId under $resolvedHome."
    }
    if ($hits.Count -gt 1)
    {
        throw ("Ambiguous Codex thread $ThreadId; found $($hits.Count) rollouts:`n  " +
            ($hits -join "`n  "))
    }

    $rolloutPath = $hits[0]
    $meta = script:Get-CodexSessionMeta -Path $rolloutPath
    if ($null -eq $meta)
    {
        throw "The rollout has no leading session_meta record: $rolloutPath"
    }
    if ($meta.id -and [string]$meta.id -ne $ThreadId)
    {
        throw "Rollout metadata id '$($meta.id)' does not match requested thread '$ThreadId'."
    }

    $archivedPrefix = [System.IO.Path]::GetFullPath($archivedDir).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $isArchived = [System.IO.Path]::GetFullPath($rolloutPath).StartsWith(
        $archivedPrefix, [StringComparison]::OrdinalIgnoreCase)

    return [pscustomobject]@{
        ThreadId      = $ThreadId
        RolloutPath   = $rolloutPath
        IsArchived    = $isArchived
        CodexHome     = $resolvedHome
        CreatedAt     = script:ConvertTo-CodexIsoTimestamp $meta.timestamp
        Cwd           = [string]$meta.cwd
        Originator    = [string]$meta.originator
        CliVersion    = [string]$meta.cli_version
        ModelProvider = [string]$meta.model_provider
        Source        = $meta.source
        SessionId     = [string]$meta.session_id
        ThreadSource  = [string]$meta.thread_source
    }
}

function New-CodexJsonlSnapshot
{
    <#
    .SYNOPSIS
        Snapshot an actively appended Codex rollout and build its .jidx.
    .DESCRIPTION
        Codex keeps active rollouts open. This reader deliberately uses
        FileShare.ReadWrite|Delete, then drops an incomplete JSON tail if the
        snapshot races an in-progress append.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [string]$FileName
    )

    if (-not [System.IO.File]::Exists($SourcePath))
    {
        throw "Codex rollout not found: $SourcePath"
    }
    [void][System.IO.Directory]::CreateDirectory($WorkingDir)
    if ([string]::IsNullOrWhiteSpace($FileName))
    {
        $FileName = [System.IO.Path]::GetFileName($SourcePath)
    }

    $snapshotPath = [System.IO.Path]::Combine($WorkingDir, $FileName)
    $indexPath = [System.IO.Path]::ChangeExtension($snapshotPath, '.jidx')
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $lineCount = 0
    $lastLine = $null

    $srcFs = [System.IO.FileStream]::new(
        $SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $srcReader = [System.IO.StreamReader]::new($srcFs, $encoding)
    $dstFs = [System.IO.FileStream]::new(
        $snapshotPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)

    try
    {
        while ($null -ne ($line = $srcReader.ReadLine()))
        {
            $trimmed = $line.Trim()
            if ($trimmed.Length -eq 0) { continue }
            $bytes = $encoding.GetBytes($trimmed)
            $dstFs.Write($bytes, 0, $bytes.Length)
            $dstFs.WriteByte(0x0A)
            $lineCount++
            $lastLine = $trimmed
        }
    }
    finally
    {
        $dstFs.Dispose()
        $srcReader.Dispose()
        $srcFs.Dispose()
    }

    $tailDropped = $false
    if ($lastLine)
    {
        try
        {
            $tailDocument = [System.Text.Json.JsonDocument]::Parse($lastLine)
            $tailDocument.Dispose()
        }
        catch
        {
            $tailDropped = $true
            $lineCount--
            $truncFs = [System.IO.FileStream]::new(
                $snapshotPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite)
            try
            {
                [long]$newLength = 0
                for ([long]$position = $truncFs.Length - 2; $position -ge 0; $position--)
                {
                    $truncFs.Position = $position
                    if ($truncFs.ReadByte() -eq 0x0A)
                    {
                        $newLength = $position + 1
                        break
                    }
                }
                $truncFs.SetLength($newLength)
            }
            finally { $truncFs.Dispose() }
        }
    }

    $idx = [JsonlIndex]::Build($snapshotPath, $indexPath)
    return [pscustomobject]@{
        SnapshotPath = $snapshotPath
        IndexPath    = $indexPath
        LineCount    = $idx.LineCount
        TailDropped  = $tailDropped
        SourcePath   = $SourcePath
    }
}

function script:New-CodexToolCallAtomic
{
    param(
        [object]$Payload,
        [string]$Timestamp,
        [string]$TurnId,
        [System.Collections.Generic.Dictionary[string, object]]$OutputMap
    )

    $callId = [string]$Payload.call_id
    if ([string]::IsNullOrWhiteSpace($callId)) { $callId = [string]$Payload.id }

    $toolName = [string]$Payload.name
    if ([string]::IsNullOrWhiteSpace($toolName)) { $toolName = [string]$Payload.tool }
    if ([string]::IsNullOrWhiteSpace($toolName)) { $toolName = [string]$Payload.type }

    $toolInput = $null
    if ($Payload.PSObject.Properties.Name -contains 'arguments')
    {
        $toolInput = script:ConvertFrom-CodexJsonString $Payload.arguments
    }
    elseif ($Payload.PSObject.Properties.Name -contains 'input')
    {
        $toolInput = script:ConvertFrom-CodexJsonString $Payload.input
    }
    elseif ($Payload.PSObject.Properties.Name -contains 'query')
    {
        $toolInput = [ordered]@{ query = $Payload.query }
    }

    $response = $null
    if ($callId -and $OutputMap.ContainsKey($callId))
    {
        $matched = $OutputMap[$callId]
        $response = [ordered]@{
            tool_use_id = $callId
            _timestamp  = $matched.Timestamp
            content     = $matched.Content
        }
    }

    return [ordered]@{
        _type        = 'tool_call'
        _source_uuid = if ($Payload.id) { [string]$Payload.id } else { $callId }
        _timestamp   = $Timestamp
        _turn_id     = $TurnId
        tool_use_id  = $callId
        tool_name    = $toolName
        tool_kind    = [string]$Payload.type
        status       = [string]$Payload.status
        input        = $toolInput
        response     = $response
    }
}

function Get-CodexExchanges
{
    <#
    .SYNOPSIS
        Normalize a snapshot rollout into exchange-envelope objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotPath,

        [Parameter(Mandatory)]
        [string]$ThreadId,

        [string]$UserLabel = 'Aipithicus'
    )

    if (-not [System.IO.File]::Exists($SnapshotPath))
    {
        throw "Snapshot not found: $SnapshotPath"
    }

    $outputMap = [System.Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal)
    $hasTurnContext = $false

    foreach ($line in [System.IO.File]::ReadLines($SnapshotPath))
    {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json -Depth 100 } catch { continue }
        if ($record.type -eq 'turn_context')
        {
            $hasTurnContext = $true
            continue
        }
        if ($record.type -ne 'response_item') { continue }
        $payload = $record.payload
        if ($payload.type -notin @(
                'function_call_output', 'custom_tool_call_output', 'tool_search_output'))
        {
            continue
        }
        $callId = [string]$payload.call_id
        if ([string]::IsNullOrWhiteSpace($callId)) { continue }

        $content = if ($payload.PSObject.Properties.Name -contains 'output')
        {
            script:ConvertFrom-CodexJsonString $payload.output
        }
        elseif ($payload.PSObject.Properties.Name -contains 'content')
        {
            $payload.content
        }
        else { $payload }

        $outputMap[$callId] = [pscustomobject]@{
            Timestamp = script:ConvertTo-CodexIsoTimestamp $record.timestamp
            Content   = $content
        }
    }

    $meta = script:Get-CodexSessionMeta -Path $SnapshotPath
    $sessionDepth = 0
    try
    {
        if ($null -ne $meta.source.subagent.thread_spawn.depth)
        {
            $sessionDepth = [int]$meta.source.subagent.thread_spawn.depth
        }
    }
    catch { $sessionDepth = 0 }

    $exchanges = [System.Collections.Generic.List[object]]::new()
    $state = [pscustomobject]@{
        CurrentTurnId = $null
        CurrentModel  = $null
        CurrentEffort = $null
        AcceptUser    = $false
        Current       = $null
    }

    $closeExchange = {
        if ($null -eq $state.Current) { return }
        $state.Current._exchange_end = $state.Current._last_timestamp
        $state.Current._turn_count = $state.Current.records.Count
        $state.Current.Remove('_last_timestamp')
        [void]$exchanges.Add($state.Current)
        $state.Current = $null
    }

    $addAtomic = {
        param([object]$Atomic)
        if ($null -eq $state.Current -or $null -eq $Atomic) { return }
        [void]$state.Current.records.Add($Atomic)
        if ($Atomic._timestamp)
        {
            $state.Current._last_timestamp = [string]$Atomic._timestamp
        }
    }

    foreach ($line in [System.IO.File]::ReadLines($SnapshotPath))
    {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $record = $line | ConvertFrom-Json -Depth 100 } catch { continue }
        $payload = $record.payload
        $timestamp = script:ConvertTo-CodexIsoTimestamp $record.timestamp

        if ($record.type -eq 'event_msg')
        {
            switch ([string]$payload.type)
            {
                'task_started'
                {
                    & $closeExchange
                    $state.CurrentTurnId = [string]$payload.turn_id
                    $state.CurrentModel = $null
                    $state.CurrentEffort = $null
                    # Imported/legacy rollouts may have no turn_context records.
                    # In that format the first user response_item follows
                    # task_started directly and is the visible prompt.
                    $state.AcceptUser = -not $hasTurnContext
                }
                'task_complete'
                {
                    if ($state.Current)
                    {
                        $state.Current._status = 'completed'
                        $state.Current._last_timestamp = $timestamp
                    }
                    & $closeExchange
                }
                'turn_aborted'
                {
                    if ($state.Current)
                    {
                        $state.Current._status = 'interrupted'
                        $state.Current._last_timestamp = $timestamp
                    }
                    & $closeExchange
                }
                'thread_rolled_back'
                {
                    & $closeExchange
                    $turnsToDrop = [Math]::Max(0, [int]$payload.num_turns)
                    for ($drop = 0; $drop -lt $turnsToDrop; $drop++)
                    {
                        if ($exchanges.Count -eq 0) { break }
                        $lastTurnId = [string]$exchanges[$exchanges.Count - 1]._turn_id
                        while ($exchanges.Count -gt 0 -and
                            [string]$exchanges[$exchanges.Count - 1]._turn_id -eq $lastTurnId)
                        {
                            $exchanges.RemoveAt($exchanges.Count - 1)
                        }
                    }
                }
                'sub_agent_activity'
                {
                    if ($state.Current)
                    {
                        & $addAtomic ([ordered]@{
                            _type        = 'subagent'
                            _source_uuid = [string]$payload.event_id
                            _timestamp   = $timestamp
                            _turn_id     = $state.CurrentTurnId
                            _agentid     = [string]$payload.agent_thread_id
                            _agenttype   = [string]$payload.kind
                            _agentdesc   = [string]$payload.agent_path
                            text         = ''
                        })
                    }
                }
            }
            continue
        }

        if ($record.type -eq 'turn_context')
        {
            if ($payload.turn_id) { $state.CurrentTurnId = [string]$payload.turn_id }
            $state.CurrentModel = [string]$payload.model
            $state.CurrentEffort = [string]$payload.effort
            $state.AcceptUser = $true
            continue
        }

        if ($record.type -ne 'response_item') { continue }

        switch ([string]$payload.type)
        {
            'message'
            {
                $role = [string]$payload.role
                $text = script:Get-CodexMessageText $payload

                if ($role -eq 'user')
                {
                    # Desktop bootstrap can persist model-visible user context
                    # before turn_context. It is not a visible human turn.
                    if (-not $state.AcceptUser -and $null -eq $state.Current) { continue }
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }

                    & $closeExchange
                    $xidx = $exchanges.Count
                    $records = [System.Collections.Generic.List[object]]::new()
                    [void]$records.Add([ordered]@{
                        _type        = 'prompt'
                        _source_uuid = if ($payload.id) { [string]$payload.id } else { $ThreadId }
                        _timestamp   = $timestamp
                        _turn_id     = $state.CurrentTurnId
                        text         = $text
                    })
                    $state.Current = [ordered]@{
                        _xid            = "$ThreadId-$($xidx.ToString('D4'))"
                        _xidx           = $xidx
                        _thread_id      = $ThreadId
                        _turn_id        = $state.CurrentTurnId
                        _source_thread  = [System.IO.Path]::GetFileName($SnapshotPath)
                        _session_uuid   = $ThreadId
                        _session_depth  = $sessionDepth
                        _exchange_start = $timestamp
                        _exchange_end   = $timestamp
                        _turn_count     = 1
                        _model          = $state.CurrentModel
                        _effort         = $state.CurrentEffort
                        _user_label     = $UserLabel
                        _status         = 'in_progress'
                        _last_timestamp = $timestamp
                        records         = $records
                    }
                    $state.AcceptUser = $false
                }
                elseif ($role -eq 'assistant' -and
                    $state.Current -and
                    -not [string]::IsNullOrWhiteSpace($text))
                {
                    & $addAtomic ([ordered]@{
                        _type        = 'response'
                        _source_uuid = if ($payload.id) { [string]$payload.id } else { $ThreadId }
                        _timestamp   = $timestamp
                        _turn_id     = $state.CurrentTurnId
                        phase        = if ($payload.phase) { [string]$payload.phase } else { 'final_answer' }
                        text         = $text
                    })
                }
            }
            'agent_message'
            {
                $text = script:Get-CodexMessageText $payload
                if ($state.Current -and -not [string]::IsNullOrWhiteSpace($text))
                {
                    & $addAtomic ([ordered]@{
                        _type        = 'response'
                        _source_uuid = if ($payload.id) { [string]$payload.id } else { $ThreadId }
                        _timestamp   = $timestamp
                        _turn_id     = $state.CurrentTurnId
                        phase        = if ($payload.phase) { [string]$payload.phase } else { 'final_answer' }
                        text         = $text
                    })
                }
            }
            'reasoning'
            {
                $text = script:Get-CodexReasoningText $payload
                if ($state.Current -and -not [string]::IsNullOrWhiteSpace($text))
                {
                    & $addAtomic ([ordered]@{
                        _type        = 'thinking'
                        _source_uuid = if ($payload.id) { [string]$payload.id } else { $ThreadId }
                        _timestamp   = $timestamp
                        _turn_id     = $state.CurrentTurnId
                        text         = $text
                    })
                }
            }
            { $_ -in @('function_call', 'custom_tool_call', 'tool_search_call') }
            {
                if ($state.Current)
                {
                    $atomic = script:New-CodexToolCallAtomic `
                        -Payload $payload `
                        -Timestamp $timestamp `
                        -TurnId $state.CurrentTurnId `
                        -OutputMap $outputMap
                    & $addAtomic $atomic
                }
            }
        }
    }

    & $closeExchange
    return $exchanges.ToArray()
}

function Export-CodexExchanges
{
    <#
    .SYNOPSIS
        Write one canonical JSONL record per exchange and build a .jidx.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Exchanges,

        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [Parameter(Mandatory)]
        [string]$ThreadId,

        [string]$OutputPrefix = 'thread'
    )

    $exchangeDir = [System.IO.Path]::Combine($WorkingDir, 'exchanges')
    [void][System.IO.Directory]::CreateDirectory($exchangeDir)
    $path = [System.IO.Path]::Combine(
        $exchangeDir, "$OutputPrefix-$ThreadId.jsonl")
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $fs = [System.IO.FileStream]::new(
        $path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try
    {
        foreach ($exchange in $Exchanges)
        {
            $json = ConvertTo-CanonicalJson -InputObject $exchange -Compress
            $bytes = $encoding.GetBytes($json)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.WriteByte(0x0A)
        }
    }
    finally { $fs.Dispose() }

    $indexPath = [System.IO.Path]::ChangeExtension($path, '.jidx')
    $idx = [JsonlIndex]::Build($path, $indexPath)
    return [pscustomobject]@{
        ExchangesPath = $path
        IndexPath     = $indexPath
        ExchangeCount = $idx.LineCount
    }
}
