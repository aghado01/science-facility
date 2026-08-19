$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\chat-export-output.ps1"
. "$PSScriptRoot\..\claude-export\claude-jso-markdown-v2.ps1"
. "$PSScriptRoot\..\codex-export\codex-jso-markdown.ps1"
. "$PSScriptRoot\..\grok-export\grok-jso-markdown.ps1"

[int]$script:AssertionCount = 0

function Assert-Equal
{
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
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
    param([bool]$Condition, [string]$Label)

    $script:AssertionCount++
    if (-not $Condition) { throw "$Label — condition was false." }
}

function Assert-BytesEqual
{
    param([byte[]]$Actual, [byte[]]$Expected, [string]$Label)

    $script:AssertionCount++
    if ($Actual.Length -ne $Expected.Length)
    {
        throw "$Label — expected $($Expected.Length) bytes, got $($Actual.Length)."
    }
    for ($index = 0; $index -lt $Actual.Length; $index++)
    {
        if ($Actual[$index] -ne $Expected[$index])
        {
            throw "$Label — byte $index expected $($Expected[$index]), got $($Actual[$index])."
        }
    }
}

function Write-JsonlFixture
{
    param([string]$Path, [object]$Value)

    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    [System.IO.File]::WriteAllText(
        $Path,
        $json + "`n",
        [System.Text.UTF8Encoding]::new($false))
}

function Assert-OutputEncodingContract
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
    Assert-Equal $parseErrors.Count 0 "$Path parses for encoding inspection"

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
            $_.Name.VariablePath.UserPath -eq 'OutputEncoding'
        })
    $label = if ($FunctionName) { $FunctionName } else { Split-Path -Leaf $Path }
    Assert-Equal $parameters.Count 1 "$label exposes OutputEncoding"
    Assert-Equal $parameters[0].StaticType ([string]) `
        "$label exposes OutputEncoding as string"
    Assert-Equal $parameters[0].DefaultValue.Extent.Text "'Utf8'" `
        "$label defaults OutputEncoding to Utf8"

    if ($ForwardedCommand)
    {
        $calls = @($body.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq $ForwardedCommand
                }, $true))
        Assert-True ($calls.Count -ge 1) "$label calls $ForwardedCommand"
        $forwardedParameters = @($calls | ForEach-Object {
                $_.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -eq 'OutputEncoding'
                }
            })
        $splatForward = $body.Extent.Text -match
            '(?m)^\s*OutputEncoding\s*=\s*\$OutputEncoding\s*$'
        Assert-True ($forwardedParameters.Count -ge 1 -or $splatForward) `
            "$label forwards OutputEncoding to $ForwardedCommand"
    }
}

$testBase = [System.IO.Path]::Combine(
    [System.IO.Path]::GetTempPath(),
    'science-facility-chat-export-tests')
[void][System.IO.Directory]::CreateDirectory($testBase)
$resolvedTestBase = [System.IO.Path]::GetFullPath($testBase)
$tempRoot = Join-Path $resolvedTestBase (
    'forensic-pair-tests-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tempRoot)

try
{
    foreach ($contract in @(
            @{
                Path = "$PSScriptRoot\..\claude-export\Export-ClaudeChat.ps1"
                ForwardedCommand = 'Invoke-ClaudeThreadExport'
            },
            @{
                Path = "$PSScriptRoot\..\codex-export\Export-CodexChat.ps1"
                ForwardedCommand = 'Invoke-CodexThreadExport'
            },
            @{
                Path = "$PSScriptRoot\..\grok-export\Export-GrokChat.ps1"
                ForwardedCommand = 'Invoke-GrokThreadExport'
            },
            @{
                Path = "$PSScriptRoot\..\claude-export\claude-jso-run.ps1"
                FunctionName = 'Invoke-ClaudeThreadExport'
                ForwardedCommand = 'ConvertTo-ClaudeMarkdownV2'
            },
            @{
                Path = "$PSScriptRoot\..\claude-export\claude-jso-run.ps1"
                FunctionName = 'Invoke-ClaudeThreadExportBatch'
                ForwardedCommand = 'Invoke-ClaudeThreadExport'
            },
            @{
                Path = "$PSScriptRoot\..\codex-export\codex-jso-run.ps1"
                FunctionName = 'Invoke-CodexThreadExport'
                ForwardedCommand = 'ConvertTo-CodexMarkdown'
            },
            @{
                Path = "$PSScriptRoot\..\grok-export\grok-jso-run.ps1"
                FunctionName = 'Invoke-GrokThreadExport'
                ForwardedCommand = 'ConvertTo-GrokMarkdown'
            },
            @{
                Path = "$PSScriptRoot\..\claude-export\claude-jso-markdown-v2.ps1"
                FunctionName = 'ConvertTo-ClaudeMarkdownV2'
            },
            @{
                Path = "$PSScriptRoot\..\codex-export\codex-jso-markdown.ps1"
                FunctionName = 'ConvertTo-CodexMarkdown'
            },
            @{
                Path = "$PSScriptRoot\..\grok-export\grok-jso-markdown.ps1"
                FunctionName = 'ConvertTo-GrokMarkdown'
            },
            @{
                Path = "$PSScriptRoot\..\Export-ChatWhitespacePair.ps1"
            }
        ))
    {
        Assert-OutputEncodingContract @contract
    }

    $wrapperTokens = $null
    $wrapperErrors = $null
    $wrapperAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path "$PSScriptRoot\..\Export-ChatWhitespacePair.ps1"),
        [ref]$wrapperTokens,
        [ref]$wrapperErrors)
    Assert-Equal $wrapperErrors.Count 0 'forensic pair wrapper parses'
    $wrapperText = $wrapperAst.Extent.Text
    Assert-Equal ([regex]::Matches(
            $wrapperText, '(?m)^\s*\[string\]\$masterMarkdown\s*=\s*ConvertTo-CodexMarkdown').Count) 1 `
        'forensic wrapper renders Codex master exactly once'
    Assert-Equal ([regex]::Matches(
            $wrapperText, '(?m)^\s*\[string\]\$masterMarkdown\s*=\s*ConvertTo-ClaudeMarkdownV2').Count) 1 `
        'forensic wrapper renders Claude master exactly once'
    Assert-Equal ([regex]::Matches(
            $wrapperText, '(?m)^\s*\[string\]\$masterMarkdown\s*=\s*ConvertTo-GrokMarkdown').Count) 1 `
        'forensic wrapper renders Grok master exactly once'
    Assert-Equal ([regex]::Matches(
            $wrapperText, '-RunThrough\s+Exchanges').Count) 3 `
        'forensic wrapper freezes all providers through exchanges'
    Assert-Equal ([regex]::Matches(
            $wrapperText, '-NormalizeWhitespace:\$false').Count) 3 `
        'forensic wrapper renders all provider masters without normalization'
    Assert-Equal ([regex]::Matches(
            $wrapperText, 'Export-ChatExportMarkdownPair').Count) 1 `
        'forensic wrapper derives one pair from the rendered master'

    $utf8Text = "Café`n"
    $utf8Bytes = ConvertTo-ChatExportBytes -Text $utf8Text
    $expectedUtf8 = [System.Text.UTF8Encoding]::new($false).GetBytes($utf8Text)
    Assert-BytesEqual $utf8Bytes $expectedUtf8 `
        'default encoding retains BOM-less UTF-8 contract'

    $surrogateText = 'A' + [string][char]0xD800 + 'B'
    $utf16Bytes = ConvertTo-ChatExportBytes `
        -Text $surrogateText `
        -OutputEncoding Utf16LE
    Assert-BytesEqual $utf16Bytes ([byte[]]@(
            0xFF, 0xFE,
            0x41, 0x00,
            0x00, 0xD8,
            0x42, 0x00)) `
        'UTF-16LE mode preserves exact code units including isolated surrogates'
    Assert-BytesEqual (ConvertTo-ChatExportBytes -Text '' -OutputEncoding Utf16LE) `
        ([byte[]]@(0xFF, 0xFE)) `
        'empty UTF-16LE output retains its byte-order mark'

    $zwsp = [char]0x200B
    $bom = [char]0xFEFF
    $combiningAcute = [char]0x0301
    $master = $bom + "---`r`nexported_at: stable`r`n---`r`n`r`n" +
        "Cafe${combiningAcute}   alpha${zwsp}   beta`r`n"
    $expectedNormalized = Format-ChatExportMarkdown -Markdown $master

    $utf8Pair = Export-ChatExportMarkdownPair `
        -MasterMarkdown $master `
        -PreNormalizationPath (Join-Path $tempRoot 'pair-utf8.pre.md') `
        -NormalizedPath (Join-Path $tempRoot 'pair-utf8.normalized.md')
    Assert-BytesEqual ([System.IO.File]::ReadAllBytes($utf8Pair.PreNormalizationPath)) `
        (ConvertTo-ChatExportBytes -Text $master -OutputEncoding Utf8) `
        'UTF-8 pre-normalization file is the exact encoded master'
    Assert-BytesEqual ([System.IO.File]::ReadAllBytes($utf8Pair.NormalizedPath)) `
        (ConvertTo-ChatExportBytes -Text $expectedNormalized -OutputEncoding Utf8) `
        'UTF-8 normalized file is exactly the encoded normalizer result'
    Assert-True $utf8Pair.NormalizationChanged `
        'pair metadata reports a normalization delta'
    Assert-Equal $utf8Pair.PairInvariant `
        'normalized = Format-ChatExportMarkdown(pre-normalization)' `
        'pair metadata states the enforced transformation'
    Assert-Equal $utf8Pair.PreNormalizationSha256 `
        (Get-FileHash -LiteralPath $utf8Pair.PreNormalizationPath -Algorithm SHA256).Hash `
        'pair metadata hashes the exact pre-normalization bytes'
    Assert-Equal $utf8Pair.NormalizedSha256 `
        (Get-FileHash -LiteralPath $utf8Pair.NormalizedPath -Algorithm SHA256).Hash `
        'pair metadata hashes the exact normalized bytes'

    $utf16Pair = Export-ChatExportMarkdownPair `
        -MasterMarkdown $master `
        -PreNormalizationPath (Join-Path $tempRoot 'pair-utf16.pre.md') `
        -NormalizedPath (Join-Path $tempRoot 'pair-utf16.normalized.md') `
        -OutputEncoding Utf16LE
    Assert-BytesEqual ([System.IO.File]::ReadAllBytes($utf16Pair.PreNormalizationPath)) `
        (ConvertTo-ChatExportBytes -Text $master -OutputEncoding Utf16LE) `
        'UTF-16LE pre-normalization file is the exact encoded master'
    Assert-BytesEqual ([System.IO.File]::ReadAllBytes($utf16Pair.NormalizedPath)) `
        (ConvertTo-ChatExportBytes -Text $expectedNormalized -OutputEncoding Utf16LE) `
        'UTF-16LE normalized file is exactly the encoded normalizer result'
    Assert-Equal $utf16Pair.ByteOrderMark 'FF FE' `
        'UTF-16LE pair metadata reports the BOM'

    $samePathRejected = $false
    try
    {
        Export-ChatExportMarkdownPair `
            -MasterMarkdown $master `
            -PreNormalizationPath (Join-Path $tempRoot 'same.md') `
            -NormalizedPath (Join-Path $tempRoot 'same.md')
    }
    catch { $samePathRejected = $true }
    Assert-True $samePathRejected 'pair helper rejects identical output paths'

    $claudePath = Join-Path $tempRoot 'claude-exchanges.jsonl'
    Write-JsonlFixture -Path $claudePath -Value ([ordered]@{
            _xid = 'claude-fixture-0000'
            _session_uuid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            _session_depth = 0
            _exchange_start = '2026-08-12T00:00:00Z'
            _model = 'claude-fixture'
            _user_label = 'Researcher'
            records = @(
                [ordered]@{ _type = 'prompt'; text = "left${zwsp}  right" },
                [ordered]@{ _type = 'response'; text = 'answer' }
            )
        })
    $claudeSourceHash = (Get-FileHash -LiteralPath $claudePath -Algorithm SHA256).Hash
    $claudeUtf16Path = Join-Path $tempRoot 'claude-utf16.md'
    ConvertTo-ClaudeMarkdownV2 `
        -ExchangesJsonlPath $claudePath `
        -OutputPath $claudeUtf16Path `
        -Exclude @() `
        -NormalizeWhitespace:$false `
        -OutputEncoding Utf16LE
    $claudeUtf16Bytes = [System.IO.File]::ReadAllBytes($claudeUtf16Path)
    Assert-True ($claudeUtf16Bytes[0] -eq 0xFF -and $claudeUtf16Bytes[1] -eq 0xFE) `
        'Claude renderer writes UTF-16LE with BOM'
    Assert-True ([System.Text.UnicodeEncoding]::new(
            $false, $true).GetString($claudeUtf16Bytes, 2, $claudeUtf16Bytes.Length - 2).Contains($zwsp)) `
        'Claude UTF-16LE output retains pre-normalization invisibles'
    Assert-Equal (Get-FileHash -LiteralPath $claudePath -Algorithm SHA256).Hash `
        $claudeSourceHash `
        'Claude UTF-16LE output does not mutate exchange JSONL'

    $codexPath = Join-Path $tempRoot 'codex-exchanges.jsonl'
    Write-JsonlFixture -Path $codexPath -Value ([ordered]@{
            _xid = 'codex-fixture-0000'
            _thread_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            _exchange_start = '2026-08-12T00:00:00Z'
            _model = 'codex-fixture'
            _user_label = 'Researcher'
            records = @(
                [ordered]@{ _type = 'prompt'; text = "left${zwsp}  right" },
                [ordered]@{ _type = 'response'; phase = 'final_answer'; text = 'answer' }
            )
        })
    $codexSourceHash = (Get-FileHash -LiteralPath $codexPath -Algorithm SHA256).Hash
    $codexUtf16Path = Join-Path $tempRoot 'codex-utf16.md'
    ConvertTo-CodexMarkdown `
        -ExchangesJsonlPath $codexPath `
        -OutputPath $codexUtf16Path `
        -Exclude @() `
        -NormalizeWhitespace:$false `
        -OutputEncoding Utf16LE
    $codexUtf16Bytes = [System.IO.File]::ReadAllBytes($codexUtf16Path)
    Assert-True ($codexUtf16Bytes[0] -eq 0xFF -and $codexUtf16Bytes[1] -eq 0xFE) `
        'Codex renderer writes UTF-16LE with BOM'
    Assert-True ([System.Text.UnicodeEncoding]::new(
            $false, $true).GetString($codexUtf16Bytes, 2, $codexUtf16Bytes.Length - 2).Contains($zwsp)) `
        'Codex UTF-16LE output retains pre-normalization invisibles'
    Assert-Equal (Get-FileHash -LiteralPath $codexPath -Algorithm SHA256).Hash `
        $codexSourceHash `
        'Codex UTF-16LE output does not mutate exchange JSONL'

    $grokPath = Join-Path $tempRoot 'grok-exchanges.jsonl'
    Write-JsonlFixture -Path $grokPath -Value ([ordered]@{
            _xid = 'grok-fixture-0000'
            _session_uuid = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
            _thread_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
            _exchange_start = '2026-08-12T00:00:00Z'
            _model = 'grok-fixture'
            _user_label = 'Researcher'
            records = @(
                [ordered]@{ _type = 'prompt'; text = "left${zwsp}  right" },
                [ordered]@{ _type = 'response'; phase = 'final_answer'; text = 'answer' }
            )
        })
    $grokSourceHash = (Get-FileHash -LiteralPath $grokPath -Algorithm SHA256).Hash
    $grokUtf16Path = Join-Path $tempRoot 'grok-utf16.md'
    ConvertTo-GrokMarkdown `
        -ExchangesJsonlPath $grokPath `
        -OutputPath $grokUtf16Path `
        -Exclude @() `
        -NormalizeWhitespace:$false `
        -OutputEncoding Utf16LE
    $grokUtf16Bytes = [System.IO.File]::ReadAllBytes($grokUtf16Path)
    Assert-True ($grokUtf16Bytes[0] -eq 0xFF -and $grokUtf16Bytes[1] -eq 0xFE) `
        'Grok renderer writes UTF-16LE with BOM'
    Assert-True ([System.Text.UnicodeEncoding]::new(
            $false, $true).GetString($grokUtf16Bytes, 2, $grokUtf16Bytes.Length - 2).Contains($zwsp)) `
        'Grok UTF-16LE output retains pre-normalization invisibles'
    Assert-Equal (Get-FileHash -LiteralPath $grokPath -Algorithm SHA256).Hash `
        $grokSourceHash `
        'Grok UTF-16LE output does not mutate exchange JSONL'

    Write-Host "PASS: $script:AssertionCount forensic pair assertions" `
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
