$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\chat-export-format-ws.ps1"
. "$PSScriptRoot\..\claude-export\claude-jso-markdown-v2.ps1"
. "$PSScriptRoot\..\codex-export\codex-jso-markdown.ps1"

[int]$script:AssertionCount = 0

function Assert-Equal
{
    param(
        [AllowNull()]
        [object]$Actual,
        [AllowNull()]
        [object]$Expected,
        [string]$Label
    )

    $script:AssertionCount++
    if ($Actual -cne $Expected)
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

function Get-FileHashText
{
    param([string]$Path)

    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [System.IO.File]::ReadAllBytes($Path)))
}

function Write-JsonlFixture
{
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    [System.IO.File]::WriteAllText(
        $Path,
        $json + "`n",
        [System.Text.UTF8Encoding]::new($false))
}

function Assert-NormalizedDocument
{
    param(
        [string]$Markdown,
        [string]$Label
    )

    Assert-True (-not $Markdown.Contains("`r")) "$Label uses LF only"
    Assert-True (-not [regex]::IsMatch(
            $Markdown, '[\u200B\u200C\u200D\u2060\uFEFF]')) `
        "$Label contains no targeted invisible characters"
    Assert-True $Markdown.EndsWith("`n") "$Label has a terminal LF"
    Assert-True (-not $Markdown.EndsWith("`n`n")) "$Label has exactly one terminal LF"
}

function Assert-NormalizationParameterContract
{
    param(
        [string]$Path,
        [string]$FunctionName,
        [string]$ForwardedCommand
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path $Path), [ref]$tokens, [ref]$parseErrors)
    Assert-Equal $parseErrors.Count 0 "$Path parses for contract inspection"

    $body = $ast
    $paramBlock = $ast.ParamBlock
    if ($FunctionName)
    {
        $functions = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $FunctionName
                }, $true))
        Assert-Equal $functions.Count 1 "$FunctionName has one definition"
        $body = $functions[0].Body
        $paramBlock = $functions[0].Body.ParamBlock
    }

    $parameters = @($paramBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -eq 'NormalizeWhitespace'
        })
    $contractLabel = if ($FunctionName) { $FunctionName } else { Split-Path -Leaf $Path }
    Assert-Equal $parameters.Count 1 "$contractLabel exposes NormalizeWhitespace"
    Assert-Equal $parameters[0].StaticType ([bool]) `
        "$contractLabel exposes NormalizeWhitespace as bool"
    Assert-Equal $parameters[0].DefaultValue.Extent.Text '$true' `
        "$contractLabel defaults NormalizeWhitespace to true"

    if ($ForwardedCommand)
    {
        $calls = @($body.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $ForwardedCommand
                }, $true))
        Assert-True ($calls.Count -ge 1) "$contractLabel calls $ForwardedCommand"
        $forwardedParameters = @($calls | ForEach-Object {
                $_.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -eq 'NormalizeWhitespace'
                }
            })
        $splatForwardsParameter = $body.Extent.Text -match
            '(?m)^\s*NormalizeWhitespace\s*=\s*\$NormalizeWhitespace\s*$'
        Assert-True ($forwardedParameters.Count -ge 1 -or $splatForwardsParameter) `
            "$contractLabel forwards NormalizeWhitespace to $ForwardedCommand"
    }
}

function Get-FirstJsonFencePayload
{
    param([string]$Markdown)

    $lines = @($Markdown -split "`n")
    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++)
    {
        $opening = [regex]::Match(
            $lines[$lineIndex],
            '^(?<prefix>(?:>[\t ]?)?)(?<run>`{3,})json$')
        if (-not $opening.Success) { continue }

        $prefix = $opening.Groups['prefix'].Value
        $run = $opening.Groups['run'].Value
        $payload = [System.Collections.Generic.List[string]]::new()
        for ($contentIndex = $lineIndex + 1;
            $contentIndex -lt $lines.Count;
            $contentIndex++)
        {
            if ($lines[$contentIndex] -eq ($prefix + $run))
            {
                return $payload -join "`n"
            }

            $content = $lines[$contentIndex]
            if ($prefix -and $content.StartsWith($prefix))
            {
                $content = $content.Substring($prefix.Length)
            }
            $payload.Add($content)
        }
    }

    throw 'No complete JSON fence was found.'
}

$testBase = [System.IO.Path]::Combine(
    [System.IO.Path]::GetTempPath(),
    'science-facility-chat-export-tests')
[void][System.IO.Directory]::CreateDirectory($testBase)
$resolvedTestBase = [System.IO.Path]::GetFullPath($testBase)
$tempRoot = Join-Path $resolvedTestBase (
    'markdown-whitespace-tests-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tempRoot)

try
{
    $zwsp = [char]0x200B
    $zwnj = [char]0x200C
    $zwj = [char]0x200D
    $wordJoiner = [char]0x2060
    $bom = [char]0xFEFF
    $combiningAcute = [char]0x0301
    $tick = [char]0x0060
    $ticks3 = [string]::new($tick, 3)
    $ticks4 = [string]::new($tick, 4)

    # Lock the public default-true contract and every forwarding seam from the
    # agent wrappers through runners to the standalone renderers.
    Assert-NormalizationParameterContract `
        -Path "$PSScriptRoot\..\claude-export\Export-ClaudeChat.ps1" `
        -ForwardedCommand 'Invoke-ClaudeThreadExport'
    Assert-NormalizationParameterContract `
        -Path "$PSScriptRoot\..\codex-export\Export-CodexChat.ps1" `
        -ForwardedCommand 'Invoke-CodexThreadExport'
    Assert-NormalizationParameterContract `
        -Path "$PSScriptRoot\..\claude-export\claude-jso-run.ps1" `
        -FunctionName 'Invoke-ClaudeThreadExport' `
        -ForwardedCommand 'ConvertTo-ClaudeMarkdownV2'
    Assert-NormalizationParameterContract `
        -Path "$PSScriptRoot\..\claude-export\claude-jso-run.ps1" `
        -FunctionName 'Invoke-ClaudeThreadExportBatch' `
        -ForwardedCommand 'Invoke-ClaudeThreadExport'
    Assert-NormalizationParameterContract `
        -Path "$PSScriptRoot\..\codex-export\codex-jso-run.ps1" `
        -FunctionName 'Invoke-CodexThreadExport' `
        -ForwardedCommand 'ConvertTo-CodexMarkdown'
    Assert-NormalizationParameterContract `
        -Path "$PSScriptRoot\..\claude-export\claude-jso-markdown-v2.ps1" `
        -FunctionName 'ConvertTo-ClaudeMarkdownV2'
    Assert-NormalizationParameterContract `
        -Path "$PSScriptRoot\..\codex-export\codex-jso-markdown.ps1" `
        -FunctionName 'ConvertTo-CodexMarkdown'

    # Shared helper: mirror the reposnapshot operation family while retaining
    # whitespace that is structural in Markdown or literal payloads.
    $raw = $bom + "---`r`nlabel: Alpha  Beta`r`n---`r`n`r`n" +
        "Cafe${combiningAcute}   prose${zwsp}   `r`n" +
        "inline   ${tick}x  y${tick}   done`r`n" +
        "    fixed  width   `r`n" +
        "-     nested  code`r`n" +
        "before`r`n`r`n`r`n`r`n`r`nafter`r`n" +
        "${ticks3}text`r`npayload  columns   `r`n`r`n`r`n`r`nend`r`n${ticks3}`r`n"
    $normalized = Format-ChatExportMarkdown -Markdown $raw

    Assert-NormalizedDocument $normalized 'shared helper output'
    Assert-True $normalized.Contains("label: Alpha  Beta`n") `
        'frontmatter scalar spacing is retained'
    Assert-True $normalized.Contains("Café prose  `n") `
        'NFC, prose compaction, invisibles, and hard breaks are normalized'
    Assert-True $normalized.Contains("inline ${tick}x  y${tick} done`n") `
        'inline code spacing is retained while surrounding prose is compacted'
    Assert-True $normalized.Contains("    fixed  width   `n") `
        'indented code spacing is retained'
    Assert-True $normalized.Contains("-     nested code`n") `
        'list continuation indentation is retained while its prose is compacted'
    Assert-True $normalized.Contains("before`n`n`nafter") `
        'ordinary blank runs are limited to two blank lines'
    Assert-True $normalized.Contains("${ticks3}text`npayload  columns   `n`n`n`nend`n${ticks3}") `
        'fenced trailing, inner, and blank whitespace is retained'
    Assert-Equal (Format-ChatExportMarkdown -Markdown $normalized) $normalized `
        'shared normalization is idempotent'
    Assert-Equal (Format-ChatExportMarkdown -Markdown '') '' `
        'empty Markdown remains empty'

    # Removing an invisible may synthesize a closing delimiter. The enclosing
    # fence is lengthened, including in House-style quoted blocks.
    $dangerousFence = "${ticks3}text`nalpha`n${tick}${tick}${zwsp}${tick}`nomega`n${ticks3}"
    $safeFence = Format-ChatExportMarkdown -Markdown $dangerousFence
    Assert-True $safeFence.StartsWith("${ticks4}text`n") `
        'ordinary opening fence is lengthened around a synthesized delimiter'
    Assert-True $safeFence.Contains("`n${ticks3}`n") `
        'synthesized delimiter remains literal fenced content'
    Assert-True $safeFence.EndsWith("${ticks4}`n") `
        'ordinary closing fence matches the lengthened opener'

    $quotedFence = "> ${ticks3}text`n> alpha`n> ${tick}${tick}${zwnj}${tick}`n> omega`n> ${ticks3}"
    $safeQuotedFence = Format-ChatExportMarkdown -Markdown $quotedFence
    Assert-True $safeQuotedFence.StartsWith("> ${ticks4}text`n") `
        'quoted opening fence is lengthened around a synthesized delimiter'
    Assert-True $safeQuotedFence.EndsWith("> ${ticks4}`n") `
        'quoted closing fence matches the lengthened opener'

    $synthesizedFence = "alpha`n${tick}${tick}${wordJoiner}${tick}`nomega"
    $safeProse = Format-ChatExportMarkdown -Markdown $synthesizedFence
    Assert-True $safeProse.Contains("`n\${ticks3}`n") `
        'a synthesized prose fence is escaped rather than activated'

    # Claude fixture covers prompt, thinking, response, subagent, tool input,
    # and tool result bodies. The JSON input deliberately uses escaped Unicode
    # after System.Text.Json serialization; the final formatter normalizes its
    # string values without changing significant double spaces.
    $claudePath = Join-Path $tempRoot 'claude-exchanges.jsonl'
    $claudeToolInput = [ordered]@{
        query  = "tool${bom}  input"
        accent = "Cafe${combiningAcute}"
        eol    = "left`r`nright"
        markup = '<tag attr="x">'
    }
    $claudeToolInput["ke${zwsp}y"] = 7
    $claudeToolInput['enabled'] = $true
    $claudeFixture = [ordered]@{
        _xid            = 'claude-fixture-0000'
        _session_uuid   = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        _session_depth  = 0
        _exchange_start = '2026-08-11T00:00:00Z'
        _model          = 'claude-fixture'
        _user_label     = "Re${zwsp}searcher"
        records         = @(
            [ordered]@{ _type = 'prompt'; text = "pro${zwsp}mpt   body`r`nnext" },
            [ordered]@{ _type = 'thinking'; text = "thi${zwnj}nking   body" },
            [ordered]@{
                _type       = 'tool_call'
                tool_name   = "To${zwj}ol"
                tool_use_id = "tool${wordJoiner}-fixture"
                input       = $claudeToolInput
                response    = [ordered]@{
                    content = "res${zwsp}ult  keeps`r`nline"
                }
            },
            [ordered]@{ _type = 'response'; text = "Cafe${combiningAcute}   final" },
            [ordered]@{
                _type      = 'subagent'
                _agenttype = 'review'
                _agentdesc = "ag${bom}ent"
                text       = "sub${wordJoiner}agent   body"
            }
        )
    }
    Write-JsonlFixture -Path $claudePath -Value $claudeFixture
    $claudeSourceHash = Get-FileHashText -Path $claudePath

    foreach ($format in @('Diarized', 'Dialogue', 'Structural', 'House'))
    {
        $markdown = ConvertTo-ClaudeMarkdownV2 `
            -ExchangesJsonlPath $claudePath `
            -Format $format `
            -Exclude @() `
            -MaxToolInputLength $null

        Assert-NormalizedDocument $markdown "Claude $format"
        Assert-True $markdown.Contains('prompt body') "Claude $format prompt is normalized"
        Assert-True $markdown.Contains('thinking body') "Claude $format thinking is normalized"
        Assert-True $markdown.Contains('**[tool: Tool]**') "Claude $format tool label is normalized"
        Assert-True $markdown.Contains('result  keeps') `
            "Claude $format tool-result literal spacing is retained"
        Assert-True $markdown.Contains('Café final') "Claude $format response is NFC-normalized"
        Assert-True $markdown.Contains('subagent body') "Claude $format subagent body is normalized"

        $toolInput = (Get-FirstJsonFencePayload -Markdown $markdown) | ConvertFrom-Json
        Assert-Equal $toolInput.query 'tool  input' `
            "Claude $format tool-input JSON removes invisibles and retains spaces"
        Assert-Equal $toolInput.accent 'Café' `
            "Claude $format tool-input JSON is NFC-normalized"
        Assert-Equal $toolInput.eol "left`nright" `
            "Claude $format tool-input JSON uses LF in string values"
        Assert-Equal $toolInput.key 7 `
            "Claude $format tool-input JSON normalizes property names"
        Assert-Equal $toolInput.enabled $true `
            "Claude $format tool-input JSON retains non-string values"
        Assert-Equal $toolInput.markup '<tag attr="x">' `
            "Claude $format tool-input JSON retains printable markup"
    }
    $claudeForensic = ConvertTo-ClaudeMarkdownV2 `
        -ExchangesJsonlPath $claudePath `
        -Format Structural `
        -Exclude @() `
        -MaxToolInputLength $null `
        -NormalizeWhitespace:$false
    Assert-True $claudeForensic.Contains("`r") `
        'Claude forensic view retains pre-postprocessor CR characters'
    Assert-True $claudeForensic.Contains([string]$zwsp) `
        'Claude forensic view retains pre-postprocessor invisible characters'
    Assert-True $claudeForensic.Contains("pro${zwsp}mpt   body`r`nnext") `
        'Claude forensic view retains prompt whitespace'
    Assert-True $claudeForensic.Contains("Cafe${combiningAcute}   final") `
        'Claude forensic view retains decomposed response text and inner spaces'
    Assert-True $claudeForensic.Contains('\uFEFF') `
        'Claude forensic view retains escaped tool JSON invisibles'

    $claudeExplicitNormalized = ConvertTo-ClaudeMarkdownV2 `
        -ExchangesJsonlPath $claudePath `
        -Format Structural `
        -Exclude @() `
        -MaxToolInputLength $null `
        -NormalizeWhitespace:$true
    Assert-NormalizedDocument $claudeExplicitNormalized `
        'Claude explicit normalized view'
    Assert-True ($claudeExplicitNormalized -cne $claudeForensic) `
        'Claude enabled and disabled views differ'

    Assert-Equal (Get-FileHashText -Path $claudePath) $claudeSourceHash `
        'Claude exchange JSONL is not mutated by Markdown normalization'

    $claudeMarkdownPath = Join-Path $tempRoot 'claude.md'
    ConvertTo-ClaudeMarkdownV2 `
        -ExchangesJsonlPath $claudePath `
        -OutputPath $claudeMarkdownPath `
        -Format Structural `
        -Exclude @() `
        -MaxToolInputLength $null
    $claudeBytes = [System.IO.File]::ReadAllBytes($claudeMarkdownPath)
    Assert-True (-not ($claudeBytes.Length -ge 3 -and
            $claudeBytes[0] -eq 0xEF -and
            $claudeBytes[1] -eq 0xBB -and
            $claudeBytes[2] -eq 0xBF)) `
        'Claude Markdown file is UTF-8 without BOM'
    Assert-Equal $claudeBytes[$claudeBytes.Length - 1] ([byte]0x0A) `
        'Claude Markdown file ends in LF'

    $claudeForensicPath = Join-Path $tempRoot 'claude-pre-normalization.md'
    ConvertTo-ClaudeMarkdownV2 `
        -ExchangesJsonlPath $claudePath `
        -OutputPath $claudeForensicPath `
        -Format Structural `
        -Exclude @() `
        -MaxToolInputLength $null `
        -NormalizeWhitespace:$false
    $claudeForensicFile = [System.IO.File]::ReadAllText($claudeForensicPath)
    Assert-True $claudeForensicFile.Contains("`r") `
        'Claude file-writing path honors disabled normalization'

    # Codex fixture additionally covers commentary and final response phases.
    $codexPath = Join-Path $tempRoot 'codex-exchanges.jsonl'
    $codexToolInput = [ordered]@{
        query  = "tool${bom}  input"
        accent = "Cafe${combiningAcute}"
        eol    = "left`r`nright"
        markup = '<tag attr="x">'
    }
    $codexToolInput["ke${zwsp}y"] = 7
    $codexToolInput['enabled'] = $true
    $codexFixture = [ordered]@{
        _xid            = 'codex-fixture-0000'
        _thread_id      = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        _exchange_start = '2026-08-11T00:00:00Z'
        _model          = 'codex-fixture'
        _user_label     = "Re${zwsp}searcher"
        records         = @(
            [ordered]@{ _type = 'prompt'; text = "pro${zwsp}mpt   body`r`nnext" },
            [ordered]@{ _type = 'thinking'; text = "thi${zwnj}nking   body" },
            [ordered]@{
                _type       = 'tool_call'
                tool_name   = "To${zwj}ol"
                tool_use_id = "tool${wordJoiner}-fixture"
                input       = $codexToolInput
                response    = [ordered]@{
                    content = "res${zwsp}ult  keeps`r`nline"
                }
            },
            [ordered]@{
                _type = 'response'; phase = 'commentary'
                text = "com${zwj}mentary   body"
            },
            [ordered]@{
                _type = 'response'; phase = 'final_answer'
                text = "Cafe${combiningAcute}   final"
            },
            [ordered]@{
                _type = 'subagent'; _agenttype = 'review'
                _agentdesc = "ag${bom}ent"; _agentid = "id${zwsp}one"
            }
        )
    }
    Write-JsonlFixture -Path $codexPath -Value $codexFixture
    $codexSourceHash = Get-FileHashText -Path $codexPath

    foreach ($format in @('Diarized', 'Dialogue', 'Structural', 'House'))
    {
        $markdown = ConvertTo-CodexMarkdown `
            -ExchangesJsonlPath $codexPath `
            -Format $format `
            -Exclude @() `
            -MaxToolInputLength $null

        Assert-NormalizedDocument $markdown "Codex $format"
        Assert-True $markdown.Contains('prompt body') "Codex $format prompt is normalized"
        Assert-True $markdown.Contains('thinking body') "Codex $format thinking is normalized"
        Assert-True $markdown.Contains('**[tool: Tool]**') "Codex $format tool label is normalized"
        Assert-True $markdown.Contains('result  keeps') `
            "Codex $format tool-result literal spacing is retained"
        Assert-True $markdown.Contains('commentary body') `
            "Codex $format commentary is normalized"
        Assert-True $markdown.Contains('Café final') "Codex $format final response is normalized"
        Assert-True $markdown.Contains('review · agent · idone') `
            "Codex $format subagent metadata is normalized"

        $toolInput = (Get-FirstJsonFencePayload -Markdown $markdown) | ConvertFrom-Json
        Assert-Equal $toolInput.query 'tool  input' `
            "Codex $format tool-input JSON removes invisibles and retains spaces"
        Assert-Equal $toolInput.accent 'Café' `
            "Codex $format tool-input JSON is NFC-normalized"
        Assert-Equal $toolInput.eol "left`nright" `
            "Codex $format tool-input JSON uses LF in string values"
        Assert-Equal $toolInput.key 7 `
            "Codex $format tool-input JSON normalizes property names"
        Assert-Equal $toolInput.enabled $true `
            "Codex $format tool-input JSON retains non-string values"
        Assert-Equal $toolInput.markup '<tag attr="x">' `
            "Codex $format tool-input JSON retains printable markup"
    }
    $codexForensic = ConvertTo-CodexMarkdown `
        -ExchangesJsonlPath $codexPath `
        -Format Structural `
        -Exclude @() `
        -MaxToolInputLength $null `
        -NormalizeWhitespace:$false
    Assert-True $codexForensic.Contains("`r") `
        'Codex forensic view retains pre-postprocessor CR characters'
    Assert-True $codexForensic.Contains([string]$zwsp) `
        'Codex forensic view retains pre-postprocessor invisible characters'
    Assert-True $codexForensic.Contains("pro${zwsp}mpt   body`r`nnext") `
        'Codex forensic view retains prompt whitespace'
    Assert-True $codexForensic.Contains("Cafe${combiningAcute}   final") `
        'Codex forensic view retains decomposed response text and inner spaces'

    $codexExplicitNormalized = ConvertTo-CodexMarkdown `
        -ExchangesJsonlPath $codexPath `
        -Format Structural `
        -Exclude @() `
        -MaxToolInputLength $null `
        -NormalizeWhitespace:$true
    Assert-NormalizedDocument $codexExplicitNormalized `
        'Codex explicit normalized view'
    Assert-True ($codexExplicitNormalized -cne $codexForensic) `
        'Codex enabled and disabled views differ'

    Assert-Equal (Get-FileHashText -Path $codexPath) $codexSourceHash `
        'Codex exchange JSONL is not mutated by Markdown normalization'

    $codexMarkdownPath = Join-Path $tempRoot 'codex.md'
    ConvertTo-CodexMarkdown `
        -ExchangesJsonlPath $codexPath `
        -OutputPath $codexMarkdownPath `
        -Format Structural `
        -Exclude @() `
        -MaxToolInputLength $null
    $codexBytes = [System.IO.File]::ReadAllBytes($codexMarkdownPath)
    Assert-True (-not ($codexBytes.Length -ge 3 -and
            $codexBytes[0] -eq 0xEF -and
            $codexBytes[1] -eq 0xBB -and
            $codexBytes[2] -eq 0xBF)) `
        'Codex Markdown file is UTF-8 without BOM'
    Assert-Equal $codexBytes[$codexBytes.Length - 1] ([byte]0x0A) `
        'Codex Markdown file ends in LF'

    $codexForensicPath = Join-Path $tempRoot 'codex-pre-normalization.md'
    ConvertTo-CodexMarkdown `
        -ExchangesJsonlPath $codexPath `
        -OutputPath $codexForensicPath `
        -Format Structural `
        -Exclude @() `
        -MaxToolInputLength $null `
        -NormalizeWhitespace:$false
    $codexForensicFile = [System.IO.File]::ReadAllText($codexForensicPath)
    Assert-True $codexForensicFile.Contains("`r") `
        'Codex file-writing path honors disabled normalization'

    Write-Host "PASS: $script:AssertionCount Markdown whitespace assertions" `
        -ForegroundColor Green
}
finally
{
    if ([System.IO.Directory]::Exists($tempRoot))
    {
        $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
        $requiredPrefix = $resolvedTestBase.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar) +
            [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolvedTempRoot.StartsWith(
                $requiredPrefix,
                [StringComparison]::OrdinalIgnoreCase))
        {
            throw "Refusing to remove test path outside chat-export tmp: $resolvedTempRoot"
        }
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}
