$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\grok-export\grok-jso-run.ps1"

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
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllLines(
        $Path, [string[]]$lines, [System.Text.UTF8Encoding]::new($false))
}

function New-GrokFixtureRecords
{
    return @(
        [ordered]@{ type = 'system'; content = 'You are Grok.' },
        [ordered]@{
            type    = 'user'
            content = @(
                [ordered]@{ type = 'text'; text = "<user_info>`nOS Version: windows`n</user_info>" }
            )
        },
        [ordered]@{
            type             = 'user'
            synthetic_reason = 'system_reminder'
            content          = @(
                [ordered]@{ type = 'text'; text = "<system-reminder>`nskills listed`n</system-reminder>" }
            )
        },
        [ordered]@{
            type         = 'user'
            prompt_index = 0
            content      = @(
                [ordered]@{ type = 'text'; text = "<user_query>`nexport this`n</user_query>" }
            )
        },
        [ordered]@{
            type    = 'reasoning'
            id      = 'rs_fixture_1'
            status  = 'completed'
            summary = @(
                [ordered]@{ type = 'summary_text'; text = 'plan the export' }
            )
        },
        [ordered]@{
            type              = 'assistant'
            content           = 'I will list the directory.'
            model_id          = 'grok-4.6-build'
            reasoning_effort  = 'xhigh'
            tool_calls        = @(
                [ordered]@{
                    id        = 'call-fixture-list-0'
                    name      = 'list_dir'
                    arguments = '{"target_directory":"D:\\fixture"}'
                }
            )
        },
        [ordered]@{
            type         = 'tool_result'
            tool_call_id = 'call-fixture-list-0'
            content      = 'dir listing'
        },
        [ordered]@{
            type             = 'assistant'
            content          = 'Done listing.'
            model_id         = 'grok-4.6-build'
            reasoning_effort = 'xhigh'
            tool_calls       = @(
                [ordered]@{
                    id        = 'call-fixture-write-1'
                    name      = 'search_replace'
                    arguments = '{"file_path":"D:\\fixture\\out.md"}'
                }
            )
        },
        [ordered]@{
            type         = 'tool_result'
            tool_call_id = 'call-fixture-write-1'
            content      = 'wrote'
        },
        [ordered]@{
            type         = 'user'
            prompt_index = 1
            content      = @(
                [ordered]@{ type = 'text'; text = "<user_query>`nspawn one`n</user_query>" }
            )
        },
        [ordered]@{
            type    = 'reasoning'
            id      = 'rs_fixture_2'
            summary = @(
                [ordered]@{ type = 'summary_text'; text = 'delegate' }
            )
        },
        [ordered]@{
            type      = 'assistant'
            content   = 'Launching a child.'
            model_id  = 'grok-4.6-build'
            tool_calls = @(
                [ordered]@{
                    id        = 'call-fixture-spawn-2'
                    name      = 'spawn_subagent'
                    arguments = '{"description":"explore fixture","subagent_type":"explore"}'
                }
            )
        },
        [ordered]@{
            type         = 'tool_result'
            tool_call_id = 'call-fixture-spawn-2'
            content      = 'child started'
        }
    )
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'grok-export-tests-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tempRoot)

try
{
    $sessionId = '01234567-89ab-4def-8123-456789abcdef'
    $grokHome = Join-Path $tempRoot 'grok-home'
    $sessionDir = Join-Path $grokHome (
        "sessions\D%3A%5Cfixture\$sessionId")
    Write-FixtureJsonl `
        -Path (Join-Path $sessionDir 'chat_history.jsonl') `
        -Records (New-GrokFixtureRecords)
    [System.IO.File]::WriteAllText(
        (Join-Path $sessionDir 'summary.json'),
        '{"info":{"id":"' + $sessionId + '","cwd":"D:\\fixture"},"current_model_id":"grok-4.6","reasoning_effort":"xhigh"}',
        [System.Text.UTF8Encoding]::new($false))

    $work = Join-Path $tempRoot 'work'
    $result = Invoke-GrokThreadExport `
        -SessionId $sessionId `
        -GrokHome $grokHome `
        -WorkingDir $work `
        -RunStamp '20260819_000000' `
        -MarkdownDir (Join-Path $tempRoot 'out') `
        -OutputPrefix 'fixture' `
        -Exclude @() `
        -NormalizeWhitespace:$false

    Assert-Equal $result.Stats.ExchangeCount 2 'fixture produces two exchanges'
    Assert-Equal $result.Stats.TailDropped $false 'complete snapshot drops no tail'
    Assert-True ([System.IO.File]::Exists($result.MarkdownPath)) 'markdown file exists'
    Assert-True ([System.IO.File]::Exists($result.ExchangesPath)) 'exchanges file exists'

    $exchanges = Get-GrokExchanges `
        -SnapshotPath $result.SnapshotPath `
        -SessionId $sessionId
    Assert-Equal $exchanges.Count 2 'Get-GrokExchanges returns two envelopes'
    Assert-Equal $exchanges[0]._status 'completed' 'first exchange is completed'
    Assert-Equal $exchanges[1]._status 'in_progress' 'last exchange is in_progress'
    Assert-Equal $exchanges[0].records[0].text 'export this' 'user_query is unwrapped'
    Assert-Equal ((@($exchanges[0].records) | ForEach-Object { $_._type }) -join ',') `
        'prompt,synthetic,synthetic,thinking,response,tool_call,response,tool_call' `
        'first exchange record order'
    Assert-Equal $exchanges[0].records[5].tool_name 'list_dir' 'first tool name'
    Assert-Equal $exchanges[0].records[5].response.content 'dir listing' 'tool result is matched'
    Assert-Equal $exchanges[0]._model 'grok-4.6-build' 'model comes from assistant record'
    Assert-Equal ((@($exchanges[1].records) | ForEach-Object { $_._type }) -join ',') `
        'prompt,thinking,response,tool_call,subagent' `
        'spawn_subagent emits tool_call and subagent'

    $markdown = Get-Content -LiteralPath $result.MarkdownPath -Raw -Encoding utf8
    Assert-True ($markdown.Contains('provider: grok')) 'frontmatter names grok'
    Assert-True ($markdown.Contains('# export this')) 'structural heading is unwrapped prompt'
    Assert-True ($markdown.Contains('skills listed')) 'empty exclude keeps synthetic'
    Assert-True ($markdown.Contains('**[tool: list_dir]**')) 'empty exclude keeps tools'

    $clean = Invoke-GrokThreadExport `
        -SessionId $sessionId `
        -GrokHome $grokHome `
        -WorkingDir (Join-Path $tempRoot 'work-clean') `
        -RunStamp '20260819_000001' `
        -MarkdownDir (Join-Path $tempRoot 'out-clean') `
        -OutputPrefix 'clean'
    $cleanMd = Get-Content -LiteralPath $clean.MarkdownPath -Raw -Encoding utf8
    Assert-True ($cleanMd.Contains('# export this')) 'default export keeps prompt'
    Assert-True (-not $cleanMd.Contains('skills listed')) 'default exclude drops synthetic'
    Assert-True (-not $cleanMd.Contains('**[tool: list_dir]**')) 'default exclude drops tools'

    $badIdThrew = $false
    try
    {
        Resolve-GrokSessionPath -SessionId 'not-a-uuid' -GrokHome $grokHome
    }
    catch { $badIdThrew = $true }
    Assert-True $badIdThrew 'malformed session id throws'

    $missingThrew = $false
    try
    {
        Resolve-GrokSessionPath `
            -SessionId '00000000-0000-4000-8000-000000000000' `
            -GrokHome $grokHome
    }
    catch { $missingThrew = $true }
    Assert-True $missingThrew 'missing session throws'

    $dupDir = Join-Path $grokHome (
        "sessions\C%3A%5Cother\$sessionId")
    [void][System.IO.Directory]::CreateDirectory($dupDir)
    [System.IO.File]::Copy(
        (Join-Path $sessionDir 'chat_history.jsonl'),
        (Join-Path $dupDir 'chat_history.jsonl'))
    $ambiguousThrew = $false
    try
    {
        Resolve-GrokSessionPath -SessionId $sessionId -GrokHome $grokHome
    }
    catch { $ambiguousThrew = $true }
    Assert-True $ambiguousThrew 'duplicate session directories throw'

    $tailHome = Join-Path $tempRoot 'tail-home'
    $tailSession = 'fedcba98-7654-4abc-8123-456789abcdef'
    $tailDir = Join-Path $tailHome ("sessions\cwd\$tailSession")
    [void][System.IO.Directory]::CreateDirectory($tailDir)
    $tailPath = Join-Path $tailDir 'chat_history.jsonl'
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $good = '{"type":"user","prompt_index":0,"content":[{"type":"text","text":"<user_query>hi</user_query>"}]}'
    [System.IO.File]::WriteAllBytes(
        $tailPath,
        $encoding.GetBytes($good + "`n{incomplete"))
    $tailSnap = New-GrokJsonlSnapshot `
        -SourcePath $tailPath `
        -WorkingDir (Join-Path $tempRoot 'tail-raw')
    Assert-True $tailSnap.TailDropped 'incomplete JSON tail is dropped'
    Assert-Equal $tailSnap.LineCount 1 'snapshot keeps only valid lines'

    Write-Host "PASS: $script:AssertionCount Grok export assertions" -ForegroundColor Green
}
finally
{
    if ([System.IO.Directory]::Exists($tempRoot))
    {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
