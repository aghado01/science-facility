$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\claude-export\claude-jso-jackson.ps1"

[int]$script:AssertionCount = 0

function Assert-Equal
{
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Label
    )

    $script:AssertionCount++
    if ($Actual -ne $Expected)
    {
        throw "$Label — expected '$Expected', got '$Actual'."
    }
}

function Assert-True
{
    param(
        [bool]$Condition,
        [string]$Label
    )

    $script:AssertionCount++
    if (-not $Condition) { throw "$Label — condition was false." }
}

function New-AssistantMessage
{
    param(
        [string]$MessageId,
        [object]$Content,
        [string]$StopReason = 'tool_use'
    )

    return [ordered]@{
        model       = 'claude-test'
        id          = $MessageId
        type        = 'message'
        role        = 'assistant'
        content     = @($Content)
        stop_reason = $StopReason
        usage       = [ordered]@{
            input_tokens                = 1
            cache_creation_input_tokens = 2
            cache_read_input_tokens     = 3
            output_tokens               = 4
        }
    }
}

function New-ClaudeFixtureRecords
{
    param(
        [string]$SessionId,
        [switch]$IncludeContinuation
    )

    $messageId = 'msg_fixture_multiblock'
    $records = [System.Collections.Generic.List[object]]::new()
    $common = [ordered]@{
        isSidechain = $false
        userType    = 'external'
        cwd         = 'D:\fixture'
        sessionId   = $SessionId
        version     = 'test'
        gitBranch   = 'main'
    }

    $records.Add([ordered]@{
            parentUuid = $null
            isSidechain = $common.isSidechain
            userType = $common.userType
            cwd = $common.cwd
            sessionId = $common.sessionId
            version = $common.version
            gitBranch = $common.gitBranch
            type = 'user'
            message = [ordered]@{ role = 'user'; content = 'implement it' }
            uuid = '10000000-0000-0000-0000-000000000001'
            timestamp = '2026-08-10T00:00:00.000Z'
        })

    $records.Add([ordered]@{
            parentUuid = '10000000-0000-0000-0000-000000000001'
            isSidechain = $common.isSidechain
            userType = $common.userType
            cwd = $common.cwd
            sessionId = $common.sessionId
            version = $common.version
            gitBranch = $common.gitBranch
            type = 'assistant'
            message = New-AssistantMessage -MessageId $messageId -Content ([ordered]@{
                    type = 'thinking'; thinking = 'first thought'; signature = 'sig-1'
                })
            uuid = '20000000-0000-0000-0000-000000000001'
            timestamp = '2026-08-10T00:00:01.000Z'
        })

    $records.Add([ordered]@{
            parentUuid = '20000000-0000-0000-0000-000000000001'
            isSidechain = $common.isSidechain
            userType = $common.userType
            cwd = $common.cwd
            sessionId = $common.sessionId
            version = $common.version
            gitBranch = $common.gitBranch
            type = 'assistant'
            message = New-AssistantMessage -MessageId $messageId -Content ([ordered]@{
                    type = 'tool_use'; id = 'toolu_fixture_alpha'; name = 'Read'
                    input = [ordered]@{ file_path = 'D:\fixture\alpha.txt' }
                })
            uuid = '20000000-0000-0000-0000-000000000002'
            timestamp = '2026-08-10T00:00:01.000Z'
        })

    $records.Add([ordered]@{
            parentUuid = '20000000-0000-0000-0000-000000000002'
            isSidechain = $common.isSidechain
            userType = $common.userType
            cwd = $common.cwd
            sessionId = $common.sessionId
            version = $common.version
            gitBranch = $common.gitBranch
            type = 'assistant'
            message = New-AssistantMessage -MessageId $messageId -Content ([ordered]@{
                    type = 'tool_use'; id = 'toolu_fixture_beta'; name = 'Grep'
                    input = [ordered]@{ pattern = 'needle'; path = 'D:\fixture' }
                })
            uuid = '20000000-0000-0000-0000-000000000003'
            timestamp = '2026-08-10T00:00:01.000Z'
        })

    $records.Add([ordered]@{
            parentUuid = '20000000-0000-0000-0000-000000000003'
            isSidechain = $common.isSidechain
            userType = $common.userType
            cwd = $common.cwd
            sessionId = $common.sessionId
            version = $common.version
            gitBranch = $common.gitBranch
            type = 'assistant'
            message = New-AssistantMessage -MessageId $messageId -StopReason 'end_turn' -Content ([ordered]@{
                    type = 'text'; text = 'done'
                })
            uuid = '20000000-0000-0000-0000-000000000004'
            timestamp = '2026-08-10T00:00:01.000Z'
        })

    $records.Add([ordered]@{
            parentUuid = '20000000-0000-0000-0000-000000000004'
            isSidechain = $common.isSidechain
            userType = $common.userType
            cwd = $common.cwd
            sessionId = $common.sessionId
            version = $common.version
            gitBranch = $common.gitBranch
            type = 'user'
            message = [ordered]@{
                role = 'user'
                content = @([ordered]@{
                        type = 'tool_result'; tool_use_id = 'toolu_fixture_alpha'
                        content = 'alpha result'; is_error = $false
                    })
            }
            uuid = '30000000-0000-0000-0000-000000000001'
            timestamp = '2026-08-10T00:00:02.000Z'
        })

    $records.Add([ordered]@{
            parentUuid = '30000000-0000-0000-0000-000000000001'
            isSidechain = $common.isSidechain
            userType = $common.userType
            cwd = $common.cwd
            sessionId = $common.sessionId
            version = $common.version
            gitBranch = $common.gitBranch
            type = 'user'
            message = [ordered]@{
                role = 'user'
                content = @([ordered]@{
                        type = 'tool_result'; tool_use_id = 'toolu_fixture_beta'
                        content = 'beta result'; is_error = $false
                    })
            }
            uuid = '30000000-0000-0000-0000-000000000002'
            timestamp = '2026-08-10T00:00:03.000Z'
        })

    if ($IncludeContinuation)
    {
        $records.Add([ordered]@{
                parentUuid = '30000000-0000-0000-0000-000000000002'
                isSidechain = $common.isSidechain
                userType = $common.userType
                cwd = $common.cwd
                sessionId = $common.sessionId
                version = $common.version
                gitBranch = $common.gitBranch
                type = 'user'
                message = [ordered]@{ role = 'user'; content = 'continue' }
                uuid = '40000000-0000-0000-0000-000000000001'
                timestamp = '2026-08-10T00:00:04.000Z'
            })
        $records.Add([ordered]@{
                parentUuid = '40000000-0000-0000-0000-000000000001'
                isSidechain = $common.isSidechain
                userType = $common.userType
                cwd = $common.cwd
                sessionId = $common.sessionId
                version = $common.version
                gitBranch = $common.gitBranch
                type = 'assistant'
                message = New-AssistantMessage -MessageId 'msg_fixture_continuation' `
                    -StopReason 'end_turn' -Content ([ordered]@{ type = 'text'; text = 'continued' })
                uuid = '40000000-0000-0000-0000-000000000002'
                timestamp = '2026-08-10T00:00:05.000Z'
            })
    }

    return $records.ToArray()
}

function Write-FixtureJsonl
{
    param(
        [string]$Path,
        [object[]]$Records
    )

    $lines = foreach ($record in $Records)
    {
        ConvertTo-CanonicalJson -InputObject $record -Compress
    }
    [System.IO.File]::WriteAllLines(
        $Path, [string[]]$lines, [System.Text.UTF8Encoding]::new($false))
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'claude-export-tests-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tempRoot)

try
{
    # One Claude response is persisted as several distinct records sharing a
    # message.id. All blocks must survive, including equal-timestamp siblings.
    $singleSource = Join-Path $tempRoot 'single-source'
    $singleWork = Join-Path $tempRoot 'single-work'
    [void][System.IO.Directory]::CreateDirectory($singleSource)
    $singleSession = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    Write-FixtureJsonl `
        -Path (Join-Path $singleSource "$singleSession.jsonl") `
        -Records (New-ClaudeFixtureRecords -SessionId $singleSession)

    $single = Export-ClaudeThread `
        -SourceDir $singleSource `
        -WorkingDir $singleWork `
        -SessionIds @($singleSession) `
        -OutputPrefix 'fixture'

    Assert-Equal $single.Stats.AfterFilter 7 'single-session filtered record count'
    Assert-Equal $single.Stats.Deduped 0 'same-message blocks are not deduplicated'
    Assert-Equal $single.Stats.DedupKey 'uuid' 'dedup key is explicit'
    Assert-Equal $single.Stats.MergedRecords 7 'all single-session records survive merge'

    $singleExchanges = Get-ClaudeExchanges `
        -MergedJsonlPath $single.MergedPath `
        -ThreadId $singleSession
    Assert-Equal $singleExchanges.Count 1 'single fixture produces one exchange'
    $singleRecords = @($singleExchanges[0].records)
    Assert-Equal (($singleRecords | ForEach-Object { $_._type }) -join ',') `
        'prompt,thinking,tool_call,tool_call,response' `
        'multi-block response order is lossless'
    Assert-Equal $singleRecords[2].tool_name 'Read' 'first equal-timestamp tool is stable'
    Assert-Equal $singleRecords[3].tool_name 'Grep' 'second equal-timestamp tool is stable'
    Assert-True ($null -ne $singleRecords[2].response) 'first tool result is matched'
    Assert-True ($null -ne $singleRecords[3].response) 'second tool result is matched'

    # A continued session carries the complete prior history forward. Those
    # copied records retain uuid and must collapse without losing their blocks.
    $chainSource = Join-Path $tempRoot 'chain-source'
    $chainWork = Join-Path $tempRoot 'chain-work'
    [void][System.IO.Directory]::CreateDirectory($chainSource)
    $rootSession = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $leafSession = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
    $rootPath = Join-Path $chainSource "$rootSession.jsonl"
    $leafPath = Join-Path $chainSource "$leafSession.jsonl"
    Write-FixtureJsonl -Path $rootPath -Records (
        New-ClaudeFixtureRecords -SessionId $rootSession)
    Write-FixtureJsonl -Path $leafPath -Records (
        New-ClaudeFixtureRecords -SessionId $leafSession -IncludeContinuation)
    [System.IO.File]::WriteAllBytes($rootPath + '.idx', [byte[]]@())
    [System.IO.File]::SetLastWriteTimeUtc($rootPath, [datetime]'2026-08-10T00:00:00Z')
    [System.IO.File]::SetLastWriteTimeUtc($leafPath, [datetime]'2026-08-10T00:01:00Z')

    $chain = Export-ClaudeThread `
        -SourceDir $chainSource `
        -WorkingDir $chainWork `
        -SessionIds @($leafSession) `
        -OutputPrefix 'fixture'

    Assert-Equal $chain.Stats.SessionCount 2 'continued fixture resolves both sessions'
    Assert-Equal $chain.Stats.AfterFilter 16 'continued fixture filtered record count'
    Assert-Equal $chain.Stats.Deduped 7 'copied history deduplicates by record uuid'
    Assert-Equal $chain.Stats.MergedRecords 9 'copied history collapses without block loss'

    $chainExchanges = Get-ClaudeExchanges `
        -MergedJsonlPath $chain.MergedPath `
        -ThreadId $rootSession
    Assert-Equal $chainExchanges.Count 2 'continued fixture produces two exchanges'
    Assert-Equal ((@($chainExchanges[0].records) | ForEach-Object { $_._type }) -join ',') `
        'prompt,thinking,tool_call,tool_call,response' `
        'continued history preserves every first-response block'
    Assert-Equal ((@($chainExchanges[1].records) | ForEach-Object { $_._type }) -join ',') `
        'prompt,response' `
        'continued session appends its new exchange'

    Write-Host "PASS: $script:AssertionCount Claude export assertions" -ForegroundColor Green
}
finally
{
    if ([System.IO.Directory]::Exists($tempRoot))
    {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
