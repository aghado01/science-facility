using namespace System.Text
using namespace System.Text.RegularExpressions
using namespace System.Collections.Generic

#Requires -Version 7.5

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
param()

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$enginePath = Join-Path $scriptRoot 'rs.lts.template.ps1'
if (Test-Path $enginePath)
{
    . $enginePath
}
else
{
    Write-Verbose "TOC template engine not found: $enginePath"
}

$shardingModulePath = Join-Path $scriptRoot 'rs.lts.sharding.psm1'
if (Test-Path $shardingModulePath)
{
    Import-Module $shardingModulePath -Force -ErrorAction Stop
}
else
{
    Write-Verbose "Sharding module not found: $shardingModulePath"
}

<#
.SYNOPSIS
    RepoSnapshot v2.7.2 — repository content snapshot and sharding module.
.DESCRIPTION
    Exports a repository's file tree and content to a structured JSON payload with
    byte-offset TOC, optional sharding, and a companion _tree.md navigation file.
#>

# ==================== PATH HELPERS ====================

function Resolve-RelPath
{
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$Path
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $rel = $full.Substring($rootFull.Length).TrimStart('\', '/')
    return ($rel -replace '\\', '/')
}

# Helper to normalize paths to a consistent format
function Norm-Path
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Path
    )
    process
    {
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

        # Simple chained approach - much cleaner!
        $clean = $Path.Trim().Replace('\', '/').Trim('/')

        # Add back trailing slash only for drive roots like 'C:/'
        if ($clean.Length -eq 2 -and $clean.EndsWith(':'))
        {
            $clean += '/'
        }

        return $clean
    }
}

function Import-TocTemplateEngine
{
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $enginePath = Join-Path $scriptRoot 'rs.lts.template.ps1'
    if (-not (Test-Path $enginePath))
    {
        Write-Verbose "TOC template engine not found: $enginePath"
        return $false
    }

    . $enginePath
    return $true
}

# ==================== CORE IGNORE PROCESSING ====================

function Get-GitIgnoredPaths
{
    param(
        [Parameter(Mandatory)] [string]$RepositoryRoot,
        [Parameter(Mandatory)] [string[]]$RelativePaths,
        [Parameter()] [int]$BatchSize = 5000,
        [Parameter()] [switch]$VerboseOutput
    )

    $ignoredSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # Resolve a single git executable explicitly
    $gitCmd = Get-Command git -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gitCmd)
    {
        if ($VerboseOutput) { Write-Verbose "Git command not found - skipping git ignore check" }
        return $ignoredSet
    }

    $isGitRepo = $False
    Push-Location $RepositoryRoot
    try
    {
        $result = & $gitCmd.Path 'rev-parse' '--is-inside-work-tree' 2>$null
        $isGitRepo = ($LASTEXITCODE -eq 0 -and $result -eq 'true')
    }
    catch
    {
        if ($VerboseOutput) { Write-Verbose "Git repo check failed: $_" }
        return $ignoredSet
    }
    finally
    {
        Pop-Location
    }

    if (-not $isGitRepo)
    {
        if ($VerboseOutput) { Write-Verbose "Not a git repository: $RepositoryRoot" }
        return $ignoredSet
    }

    for ($i = 0; $i -lt $RelativePaths.Count; $i += $BatchSize)
    {
        $endIndex = [Math]::Min($i + $BatchSize - 1, $RelativePaths.Count - 1)
        $batch = $RelativePaths[$i..$endIndex]

        try
        {
            $sb = [System.Text.StringBuilder]::new()
            foreach ($path in $batch)
            {
                [void]$sb.AppendLine($path)
            }

            $tempFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tempFile, $sb.ToString(), [System.Text.UTF8Encoding]::new($False))

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $gitCmd.Path
            $psi.WorkingDirectory = $RepositoryRoot
            $psi.UseShellExecute = $False
            $psi.RedirectStandardInput = $True
            $psi.RedirectStandardOutput = $True
            $psi.RedirectStandardError = $True
            $psi.CreateNoWindow = $True
            [void]$psi.ArgumentList.Add('check-ignore')
            [void]$psi.ArgumentList.Add('--stdin')
            [void]$psi.ArgumentList.Add('--quiet')
            [void]$psi.ArgumentList.Add('--no-index')

            $process = [System.Diagnostics.Process]::Start($psi)
            $process.StandardInput.Write($sb.ToString())
            $process.StandardInput.Close()

            $output = $process.StandardOutput.ReadToEnd()
            $process.WaitForExit()
            $exitCode = $process.ExitCode
            $process.Dispose()

            if ($exitCode -eq 0)
            {
                foreach ($line in ($output -split "`r?`n"))
                {
                    $trimmed = $line.Trim()
                    if ($trimmed)
                    {
                        $pathname = $trimmed -replace '\\', '/'
                        [void]$ignoredSet.Add($pathname)
                    }
                }
            }
        }
        catch
        {
            Write-Warning "Git check-ignore failed for batch starting at $i`: $_"
        }
        finally
        {
            if ($tempFile -and (Test-Path $tempFile))
            {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $ignoredSet
}


function Read-GitIgnoreRules
{
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter()] [string]$Source = $null
    )

    if (-not (Test-Path $FilePath)) { return @() }

    try
    {
        $content = [System.IO.File]::ReadAllText($FilePath, [System.Text.UTF8Encoding]::new($False))
    }
    catch
    {
        Write-Warning "Failed to read ignore file: $FilePath"
        return @()
    }

    $rules = [List[object]]::new()
    $lineNum = 0

    foreach ($rawLine in ($content -split "`r?`n"))
    {
        $lineNum++
        $line = $rawLine.Trim()

        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#'))
        {
            continue
        }

        $isNegation = $False
        if ($line.StartsWith('!'))
        {
            $isNegation = $True
            $line = $line.Substring(1).Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
        }

        $anchored = $line.StartsWith('/')
        $dirOnly = $line.EndsWith('/')

        $pattern = $line
        if ($anchored) { $pattern = $pattern.Substring(1) }
        if ($dirOnly) { $pattern = $pattern.TrimEnd('/') }

        $rules.Add([pscustomobject]@{
                Pattern      = $pattern
                IsNegation   = $isNegation
                Anchored     = $anchored
                DirOnly      = $dirOnly
                Source       = $Source ?? $FilePath
                LineNumber   = $lineNum
                OriginalLine = $rawLine
            })
    }

    return $rules
}

function Convert-GitIgnoreGlobToRegex
{
    param(
        [Parameter(Mandatory)] [string]$Pattern,
        [Parameter()] [bool]$Anchored = $False,
        [Parameter()] [bool]$DirOnly = $False
    )

    $sb = [StringBuilder]::new()
    $i = 0
    $len = $Pattern.Length

    if ($Anchored)
    {
        [void]$sb.Append('^')
    }
    else
    {
        [void]$sb.Append('^(?:.*\/)?')
    }

    while ($i -lt $len)
    {
        $c = $Pattern[$i]

        switch ($c)
        {
            '.' { [void]$sb.Append('\.'); $i++ }
            '+' { [void]$sb.Append('\+'); $i++ }
            '(' { [void]$sb.Append('\('); $i++ }
            ')' { [void]$sb.Append('\)'); $i++ }
            '|' { [void]$sb.Append('\|'); $i++ }
            '^' { [void]$sb.Append('\^'); $i++ }
            '$' { [void]$sb.Append('\$'); $i++ }
            '{' { [void]$sb.Append('\{'); $i++ }
            '}' { [void]$sb.Append('\}'); $i++ }
            '[' { [void]$sb.Append('\['); $i++ }
            ']' { [void]$sb.Append('\]'); $i++ }
            '\' { [void]$sb.Append('\\'); $i++ }

            '*'
            {
                if (($i + 1) -lt $len -and $Pattern[$i + 1] -eq '*')
                {
                    $i += 2
                    if ($i -lt $len -and $Pattern[$i] -eq '/')
                    {
                        [void]$sb.Append('(?:.*\/)?')
                        $i++
                    }
                    else
                    {
                        [void]$sb.Append('.*')
                    }
                }
                else
                {
                    [void]$sb.Append('[^\/]*')
                    $i++
                }
            }

            '?'
            {
                [void]$sb.Append('[^\/]')
                $i++
            }

            '/'
            {
                [void]$sb.Append('\/')
                $i++
            }

            default
            {
                [void]$sb.Append([Regex]::Escape([string]$c))
                $i++
            }
        }
    }

    # For gitignore semantics we allow "match directory plus anything under it"
    [void]$sb.Append('(?:\/.*)?$')
    return $sb.ToString()
}

function Build-GitIgnoreMatcher
{
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Rules,
        [Parameter()] [bool]$CaseSensitive = $False
    )

    if ($Rules.Count -eq 0)
    {
        return { param($p, $d) $False }
    }

    $compiledRules = foreach ($rule in $Rules)
    {
        try
        {
            $regexPattern = Convert-GitIgnoreGlobToRegex -Pattern $rule.Pattern -Anchored $rule.Anchored -DirOnly $rule.DirOnly
            $regexOptions = if ($CaseSensitive) { [RegexOptions]::Compiled } else { [RegexOptions]::Compiled -bor [RegexOptions]::IgnoreCase }
            [pscustomobject]@{
                Regex        = [Regex]::new($regexPattern, $regexOptions)
                IsNegation   = $rule.IsNegation
                DirOnly      = $rule.DirOnly
                Source       = $rule.Source
                Pattern      = $rule.Pattern
                OriginalLine = $rule.OriginalLine
            }
        }
        catch
        {
            Write-Warning "Failed to compile regex for pattern '$($rule.Pattern)' from $($rule.Source):$($rule.LineNumber) - $_"
            continue
        }
    }

    return {
        param([string]$RelativePath, [bool]$IsDirectory)

        $normalizedPath = $RelativePath -replace '\\', '/'
        $decision = $null

        foreach ($compiledRule in $compiledRules)
        {
            if ($compiledRule.DirOnly -and -not $IsDirectory)
            {
                $parentMatch = $compiledRule.Regex.IsMatch($normalizedPath)
                if (-not $parentMatch) { continue }
            }

            if ($compiledRule.Regex.IsMatch($normalizedPath))
            {
                $decision = if ($compiledRule.IsNegation) { $False } else { $True }
            }
        }

        return [bool]($decision -eq $True)
    }
}

function Find-ExternalIgnoreRules
{
    param(
        [Parameter(Mandatory)] [string]$Root,
        [string]$IgnoreFileName = ".ignore",
        [Parameter()] [switch]$UseParentIgnore
    )

    if ([string]::IsNullOrWhiteSpace($IgnoreFileName)) { return @() }

    $rootFull = [IO.Path]::GetFullPath($Root)
    $dir = $rootFull
    $all = [List[object]]::new()
    while ($True)
    {
        $candidate = Join-Path $dir $IgnoreFileName
        if (Test-Path $candidate)
        {
            $rules = Read-GitIgnoreRules -FilePath $candidate
            if ($rules.Count -gt 0)
            {
                $all.AddRange($rules)
            }
        }
        $parent = [IO.Directory]::GetParent($dir)
        if (-not $UseParentIgnore) { break }
        if ($null -eq $parent) { break }
        if ($parent.FullName -eq $dir) { break }
        $dir = $parent.FullName
    }

    $result = [System.Linq.Enumerable]::Reverse($all)
    return @($result)
}

function Normalize-PatternArray
{
    param(
        [Parameter()] [AllowEmptyCollection()] [string[]]$Patterns
    )

    if (-not $Patterns -or $Patterns.Count -eq 0)
    {
        return @()
    }

    $normalized = @()
    foreach ($pattern in $Patterns)
    {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }

        if ($pattern -match '^\.[\w]+$')
        {
            $normalized += "*$pattern"
        }
        else
        {
            $normalized += $pattern
        }
    }

    return $normalized
}

function New-PathInclusionTester
{
    param(
        [Parameter()] [scriptblock]$GitIgnoreMatcher = { param($p, $d) $False },
        [Parameter()] [scriptblock]$ExternalIgnoreMatcher = { param($p, $d) $False },
        [Parameter()] [AllowEmptyCollection()] [string[]]$ExtraExcludePatterns = @(),
        [Parameter()] [AllowEmptyCollection()] [string[]]$ExtraIncludePatterns = @(),
        [Parameter()] [AllowEmptyCollection()] [string[]]$IncludePatterns = @(),
        [Parameter()] [AllowEmptyCollection()] [string[]]$ExcludePatterns = @(),
        [Parameter()] [HashSet[string]]$GitIgnoredPaths = $null,
        [Parameter()] [bool]$CaseSensitive = $False
    )

    # Normalize all pattern arrays
    $ExtraExcludePatterns = Normalize-PatternArray -Patterns $ExtraExcludePatterns
    $ExtraIncludePatterns = Normalize-PatternArray -Patterns $ExtraIncludePatterns
    $IncludePatterns = Normalize-PatternArray -Patterns $IncludePatterns
    $ExcludePatterns = Normalize-PatternArray -Patterns $ExcludePatterns

    # SIMPLIFIED LOGIC: Only create matchers for non-empty, non-wildcard patterns
    $hasRealIncludePatterns = ($IncludePatterns.Count -gt 0 -and $IncludePatterns -notcontains "*")
    $hasExcludePatterns = ($ExcludePatterns.Count -gt 0)
    $hasExtraIgnore = ($ExtraExcludePatterns.Count -gt 0)
    $hasExtraInclude = ($ExtraIncludePatterns.Count -gt 0)

    # Build matchers only when needed
    $includeMatcher = if ($hasRealIncludePatterns)
    {
        $rules = $IncludePatterns | ForEach-Object {
            [pscustomobject]@{ Pattern = $_; IsNegation = $False; Anchored = $_.StartsWith('/'); DirOnly = $_.EndsWith('/'); Source = '<cli>' }
        }
        Build-GitIgnoreMatcher -Rules $rules -CaseSensitive $CaseSensitive
    }
    else
    {
        { param($p, $d) $True }  # Allow all when no real include patterns
    }

    $excludeMatcher = if ($hasExcludePatterns)
    {
        $rules = $ExcludePatterns | ForEach-Object {
            [pscustomobject]@{ Pattern = $_; IsNegation = $False; Anchored = $_.StartsWith('/'); DirOnly = $_.EndsWith('/'); Source = '<cli>' }
        }
        Build-GitIgnoreMatcher -Rules $rules -CaseSensitive $CaseSensitive
    }
    else
    {
        { param($p, $d) $False }
    }

    $extraIgnoreMatcher = if ($hasExtraIgnore)
    {
        $rules = $ExtraExcludePatterns | ForEach-Object {
            [pscustomobject]@{ Pattern = $_; IsNegation = $False; Anchored = $_.StartsWith('/'); DirOnly = $_.EndsWith('/'); Source = '<cli>' }
        }
        Build-GitIgnoreMatcher -Rules $rules -CaseSensitive $CaseSensitive
    }
    else
    {
        { param($p, $d) $False }
    }

    $extraIncludeMatcher = if ($hasExtraInclude)
    {
        $rules = $ExtraIncludePatterns | ForEach-Object {
            [pscustomobject]@{ Pattern = $_; IsNegation = $False; Anchored = $_.StartsWith('/'); DirOnly = $_.EndsWith('/'); Source = '<cli>' }
        }
        Build-GitIgnoreMatcher -Rules $rules -CaseSensitive $CaseSensitive
    }
    else
    {
        { param($p, $d) $False }
    }

    $gitIgnored = $GitIgnoredPaths ?? [HashSet[string]]::new()

    # CLEAR, SIMPLE DECISION LOGIC
    $tester = {
        param(
            [Parameter(Mandatory)] [string]$RelativePath,
            [Parameter(Mandatory)] [bool]$IsDirectory
        )

        $normalizedPath = $RelativePath -replace '\\', '/'

        # 1. FORCE INCLUDES always win
        if ($extraIncludeMatcher.InvokeReturnAsIs($normalizedPath, $IsDirectory))
        {
            return $True
        }

        # 2. If we have specific include patterns (not just "*"), evaluate early and treat as allowlist
        $incMatch = $False
        if ($hasRealIncludePatterns)
        {
            $incMatch = [bool]($includeMatcher.InvokeReturnAsIs($normalizedPath, $IsDirectory))
            if (-not $incMatch) { return $False } # doesn't match allowlist
        }

        # 3. Check all exclusion sources
        if ($excludeMatcher.InvokeReturnAsIs($normalizedPath, $IsDirectory)) { return $False }
        # If IncludePatterns explicitly matched, let it override ignore sources
        if (-not $incMatch)
        {
            if ($extraIgnoreMatcher.InvokeReturnAsIs($normalizedPath, $IsDirectory)) { return $False }
            if ($ExternalIgnoreMatcher.InvokeReturnAsIs($normalizedPath, $IsDirectory)) { return $False }
            if ($GitIgnoreMatcher.InvokeReturnAsIs($normalizedPath, $IsDirectory)) { return $False }
            if ($gitIgnored.Contains($normalizedPath)) { return $False }
        }

        # 4. Default: include
        return $True
    }.GetNewClosure()

    return $tester
}

function Test-IsBinaryFile
{
    param([Parameter(Mandatory)] [string]$Path)

    try
    {
        $fileInfo = [System.IO.FileInfo]::new($Path)
        if ($fileInfo.Length -eq 0) { return $False }

        if ($fileInfo.Length -le 1024)
        {
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            return ([Array]::IndexOf($bytes, 0) -ge 0)
        }

        $buffer = New-Object byte[] 4096
        $stream = [System.IO.File]::OpenRead($Path)
        try
        {
            $bytesRead = $stream.Read($buffer, 0, 4096)
            return ([Array]::IndexOf($buffer[0..($bytesRead - 1)], 0) -ge 0)
        }
        finally
        {
            $stream.Close()
        }
    }
    catch
    {
        return $True
    }
}

function Get-FilteredFiles
{
    param(
        [string]$Root,
        [string[]]$ExcludeDirectories = @(),
        [string[]]$ExcludePatterns = @(),
        [int]$MaxFileCount = 50000
    )

    $files = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)

    while ($stack.Count -gt 0 -and $files.Count -lt $MaxFileCount)
    {
        $currentDir = $stack.Pop()

        try
        {
            $dirName = Split-Path $currentDir -Leaf
            $relativePath = $currentDir.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')

            $shouldSkipDir = $False
            foreach ($excludeDir in $ExcludeDirectories)
            {
                if ($dirName -eq $excludeDir -or $relativePath -like "*/$excludeDir" -or $relativePath -eq $excludeDir)
                {
                    $shouldSkipDir = $True
                    Write-Verbose "Skipping entire directory: $relativePath"
                    break
                }
            }
            if ($shouldSkipDir) { continue }

            Get-ChildItem -LiteralPath $currentDir -File -ErrorAction SilentlyContinue | ForEach-Object {
                if ($files.Count -lt $MaxFileCount)
                {
                    $files.Add($_.FullName)
                }
            }

            Get-ChildItem -LiteralPath $currentDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $stack.Push($_.FullName)
            }
        }
        catch
        {
            Write-Verbose "Skipping inaccessible directory: $currentDir"
        }
    }

    return $files.ToArray()
}


# ==================== CONTENT PROCESSING HELPERS ====================

function Filter-Content
{
    <#
    .SYNOPSIS
        Filters content based on include/exclude patterns or indicators.

    .DESCRIPTION
        - Applies regex-based filtering to include or exclude content.
        - Supports predefined indicators like 'function-signatures'.
    #>
    param(
        [Parameter()] [AllowEmptyCollection()] [string[]]$IncludeContentPatterns = @(),
        [Parameter()] [AllowEmptyCollection()] [string[]]$ExcludeContentPatterns = @(),
        [Parameter()] [string[]]$ContentIndicators = @(),
        [Parameter(Mandatory)] [string]$Content
    )

    # Normalize patterns
    $IncludeContentPatterns = Normalize-PatternArray -Patterns $IncludeContentPatterns
    $ExcludeContentPatterns = Normalize-PatternArray -Patterns $ExcludeContentPatterns

    # Predefined indicators
    $indicatorPatterns = @{
        'function-signatures' = '(?m)^\s*(function|def|sub)\s+\w+'
    }

    foreach ($indicator in $ContentIndicators)
    {
        if ($indicatorPatterns.ContainsKey($indicator))
        {
            $IncludeContentPatterns += $indicatorPatterns[$indicator]
        }
    }

    # Apply filtering
    $lines = $Content -split "`n"
    $filteredLines = @()

    foreach ($line in $lines)
    {
        $include = $True

        # Check exclude patterns
        foreach ($pattern in $ExcludeContentPatterns)
        {
            if ($line -match $pattern)
            {
                $include = $False
                break
            }
        }

        # Check include patterns
        if ($include -and $IncludeContentPatterns.Count -gt 0)
        {
            $include = $IncludeContentPatterns | ForEach-Object { $line -match $_ } | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count -gt 0
        }

        if ($include)
        {
            $filteredLines += $line
        }
    }

    return $filteredLines -join "`n"
}


# ==================== CONTENT PREVIEW HELPER ====================
function Normalize-FileContent
{
    <#
    .SYNOPSIS
        Staged content normalization: universal cleanup, IDE garbage removal, and
        optional language-specific comment stripping.

    .DESCRIPTION
        Stage 1 — Universal: CRLF/CR → LF, non-breaking spaces → regular spaces.
        Stage 2 — Structural: strip leading/trailing blank lines, collapse 3+ blanks → 2.
        Stage 3 — IDE garbage: remove #region/#endregion and //region markers.
        Stage 4 — Comments (when StripComments=$true): language-specific removal
                   dispatched by file extension. PS files use the PS tokenizer so
                   string literals are never corrupted; .cs/.py/.js families use a
                   combined string-or-comment scan for the same guarantee.
                   Supported: .ps1/.psm1/.psd1, .cs, .py, .js/.ts/.jsx/.tsx.
    #>
    param(
        [Parameter(Mandatory)] [string]$Content,
        [Parameter(Mandatory)] [string]$RelPath,
        [bool]$StripComments = $false
    )

    if ([string]::IsNullOrEmpty($Content)) { return $Content }

    # Stage 1 — Universal normalization
    $text = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    $text = $text -replace '\u00A0', ' '

    # Stage 2 — Structural cleanup
    $text = $text -replace '^\s*[\r\n]+', ''
    $text = $text -replace '[\r\n]+\s*$', "`n"
    $text = $text -replace "`n{3,}", "`n`n"

    # Stage 3 — IDE/editor garbage
    $text = $text -replace '(?m)^\s*#\s*region.*$', ''
    $text = $text -replace '(?m)^\s*#\s*endregion.*$', ''
    $text = $text -replace '(?m)^\s*//\s*#?region.*$', ''
    $text = $text -replace '(?m)^\s*//\s*#?endregion.*$', ''

    # Stage 4 — Language-specific comment removal
    if ($StripComments)
    {
        $ext = [IO.Path]::GetExtension($RelPath).ToLower()
        switch -Regex ($ext)
        {
            '\.(ps1|psm1|psd1)$'
            {
                # Tokenizer-based stripping: a bare regex over raw text eats <#..#>
                # sequences inside string literals and can delete arbitrary spans
                # (issues/lts-stripcomments-string-corruption.md). The PS parser
                # yields exact comment token extents; string/here-string content is
                # never touched. The tokenizer is error-recovering, so Comment
                # tokens are used regardless of parse errors — broken/half-written
                # files still get stripped, and the worst tokenizer failure mode
                # (unterminated string swallowing the tail) degrades to
                # under-stripping, never to span deletion.
                $psTokens = $null
                $psParseErrors = $null
                $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$psTokens, [ref]$psParseErrors)
                $commentKind = [System.Management.Automation.Language.TokenKind]::Comment
                $stripSpans = [System.Collections.Generic.List[pscustomobject]]::new()
                foreach ($tok in @($psTokens))
                {
                    if ($tok.Kind -ne $commentKind) { continue }
                    # Frontmatter: #Requires directives and a line-1 shebang lex as
                    # ordinary Comment tokens but must never be stripped.
                    if ($tok.Text -match '^#requires\b') { continue }
                    if ($tok.Extent.StartOffset -eq 0 -and $tok.Text.StartsWith('#!')) { continue }

                    $s = $tok.Extent.StartOffset
                    $e = $tok.Extent.EndOffset

                    # Whole-line? (only whitespace between line start and token)
                    $ls = $s
                    while ($ls -gt 0 -and ($text[$ls - 1] -eq ' ' -or $text[$ls - 1] -eq "`t")) { $ls-- }
                    $ownsLineStart = ($ls -eq 0 -or $text[$ls - 1] -eq "`n")

                    if ($tok.Text -notmatch '^<#' -and -not $ownsLineStart)
                    {
                        continue   # '#' comment after code: keep (parity with prior line-anchored regex)
                    }

                    if ($ownsLineStart)
                    {
                        # Consume indentation and, when nothing but whitespace
                        # follows on the line, the trailing newline as well.
                        $s = $ls
                        $we = $e
                        while ($we -lt $text.Length -and ($text[$we] -eq ' ' -or $text[$we] -eq "`t")) { $we++ }
                        if ($we -ge $text.Length) { $e = $we }
                        elseif ($text[$we] -eq "`n") { $e = $we + 1 }
                    }

                    $stripSpans.Add([pscustomobject]@{ Start = $s; End = $e })
                }

                if ($stripSpans.Count -gt 0)
                {
                    $sb = [System.Text.StringBuilder]::new($text.Length)
                    $pos = 0
                    foreach ($span in $stripSpans)
                    {
                        if ($span.Start -gt $pos) { $null = $sb.Append($text.Substring($pos, $span.Start - $pos)) }
                        if ($span.End -gt $pos) { $pos = $span.End }
                    }
                    if ($pos -lt $text.Length) { $null = $sb.Append($text.Substring($pos)) }
                    $text = $sb.ToString()
                }
            }
            '\.cs$'
            {
                # Single combined scan: string literals and comments are alternatives
                # of one pattern, so a comment marker inside a string (or a quote
                # inside a comment) can never pair across boundaries.
                $csPattern = '(?sm)@"(?:[^"]|"")*"|"(?:\\.|[^"\\\n])*"|''(?:\\.|[^''\\\n])*''|/\*.*?\*/|(?<slc>^[ \t]*//[^\n]*)|//[^\n]*'
                $text = [regex]::Replace($text, $csPattern, {
                        param($m)
                        if ($m.Groups['slc'].Success) { return '' }      # standalone /// or // line
                        if ($m.Value.StartsWith('/*')) { return '' }     # block comment
                        return $m.Value                                  # string literal / trailing // kept
                    })
            }
            '\.py$'
            {
                # Triple-quoted literals in statement position (line starts with the
                # literal) are docstrings and stripped; every other string literal is
                # preserved verbatim.
                $pyPattern = '(?sm)(?<ds>^[ \t]*(?:""".*?"""|''''''.*?''''''))|""".*?"""|''''''.*?''''''|"(?:\\.|[^"\\\n])*"|''(?:\\.|[^''\\\n])*''|(?<sc>^[ \t]*#[^\n]*)|#[^\n]*'
                $text = [regex]::Replace($text, $pyPattern, {
                        param($m)
                        if ($m.Index -eq 0 -and $m.Value.StartsWith('#!')) { return $m.Value }   # shebang frontmatter
                        if ($m.Groups['ds'].Success) { return '' }       # docstring
                        if ($m.Groups['sc'].Success) { return '' }       # standalone # line
                        return $m.Value                                  # strings / trailing # kept
                    })
            }
            '\.(js|ts|jsx|tsx)$'
            {
                $jsPattern = '(?sm)`(?:\\.|[^`\\])*`|"(?:\\.|[^"\\\n])*"|''(?:\\.|[^''\\\n])*''|/\*.*?\*/|(?<slc>^[ \t]*//[^\n]*)|//[^\n]*'
                $text = [regex]::Replace($text, $jsPattern, {
                        param($m)
                        if ($m.Groups['slc'].Success) { return '' }
                        if ($m.Value.StartsWith('/*')) { return '' }
                        return $m.Value
                    })
            }
        }
        # Re-collapse blank lines left by comment removal
        $text = $text -replace "`n{3,}", "`n`n"
    }

    return $text.TrimEnd()
}


function New-ContentAndPreview
{
    <#
    .SYNOPSIS
        Produce a preview object from already-filtered (and optionally minified) content.

    .DESCRIPTION
        This helper was missing in some refactors; the sequential processing path calls it
        to obtain a uniform @{ content; preview } object. Parallel path inlines equivalent logic.
        Keeping this lightweight avoids duplicate minification (caller handles that).

    .PARAMETER Content
        The (already filtered/minified) full text.

    .PARAMETER MaxPreviewChars
        Maximum characters budget for preview truncation logic.

    .OUTPUTS
        PSCustomObject with properties: content, preview
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Content,
        [int]$MaxPreviewChars = 200
    )

    $processed = $Content

    # Truncation strategy mirrors the parallel block (head + tail with omission marker)
    $preview = ""
    if ($processed.Length -le $MaxPreviewChars)
    {
        $preview = $processed
    }
    else
    {
        $headLen = [Math]::Min([Math]::Floor($MaxPreviewChars * 0.6), $processed.Length)
        $tailLen = [Math]::Min($MaxPreviewChars - $headLen - 20, [Math]::Max(0, $processed.Length - $headLen - 20))
        $head = $processed.Substring(0, $headLen)
        $tail = if ($tailLen -gt 0) { $processed.Substring($processed.Length - $tailLen) } else { '' }
        $preview = "$head`n<...omitted...>`n$tail"
    }

    return [pscustomobject]@{ content = $processed; preview = $preview }
}

function Get-EntryByteOffsets
{
    <#
    .SYNOPSIS
        Derive intra-entry byte offsets for the four TOC columns from a serialized JSON entry string.

    .DESCRIPTION
        Matches the "content":"..." value inside a compact JSON entry, then converts .NET char indices
        to UTF-8 byte offsets (using GetByteCount on prefix substrings). All offsets are absolute —
        BaseOffset anchors them to their position in the containing file.

        Returns:
          row_offset        — BaseOffset (start of the { opening the record)
          row_meta_end      — last byte before the "content": key (inclusive)
          row_content_begin — first byte of the content string value (after the opening ")
          row_content_end   — last byte of the content string value (before the closing ")

        All three content offsets are null when "content" is absent or null (binary/excluded files).
        When content is an empty string "", row_content_begin == row_content_end (zero-length span,
        distinct from null — signals "ingested but empty" vs "not ingested").
    #>
    param(
        [Parameter(Mandatory)][string]$EntryJson,
        [Parameter(Mandatory)][long]$BaseOffset
    )

    $enc = [Text.Encoding]::UTF8
    $m = [regex]::Match($EntryJson, '"content":"((?:[^"\\]|\\.)*)"')

    if ($m.Success)
    {
        $rowMetaEnd = $BaseOffset + $enc.GetByteCount($EntryJson.Substring(0, $m.Index)) - 1
        $contentStartChar = $m.Groups[1].Index
        $rowContentBegin = $BaseOffset + $enc.GetByteCount($EntryJson.Substring(0, $contentStartChar))
        $contentLen = $m.Groups[1].Length
        $rowContentEnd = if ($contentLen -gt 0)
        {
            $rowContentBegin + $enc.GetByteCount($EntryJson.Substring($contentStartChar, $contentLen)) - 1
        }
        else
        {
            $rowContentBegin
        }
    }
    else
    {
        $rowMetaEnd = $null; $rowContentBegin = $null; $rowContentEnd = $null
    }

    return [pscustomobject]@{
        row_offset        = $BaseOffset
        row_meta_end      = $rowMetaEnd
        row_content_begin = $rowContentBegin
        row_content_end   = $rowContentEnd
    }
}

# ==================== TREE RENDERERS ====================

function Build-DirectoryTree
{
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$IncludedPaths,
        [Parameter()] [int]$MaxDepth = 6,
        [Parameter()] [int]$MaxFilesPerDir = 100,
        [Parameter()] [hashtable]$FileSizeMap = @{}
    )

    $node = [pscustomobject]@{
        name           = [IO.Path]::GetFileName($Root)
        path           = ''
        type           = 'dir'
        children       = @()
        omitted_counts = [pscustomobject]@{ files = 0; dirs = 0 }
    }

    if (-not $IncludedPaths -or $IncludedPaths.Count -eq 0)
    {
        return $node
    }

    $byDir = $IncludedPaths | Group-Object { [IO.Path]::GetDirectoryName($_) -replace '\\', '/' }
    $map = @{ '' = $node }

    foreach ($g in $byDir)
    {
        $dirRel = ($g.Name ?? '') -replace '^/', ''
        $parts = @()
        if ($dirRel) { $parts = $dirRel.Split('/') }
        $cursorKey = ''
        $cursor = $node

        foreach ($p in $parts)
        {
            $cursorKey = if ($cursorKey) { "$cursorKey/$p" } else { $p }
            if (-not $map.ContainsKey($cursorKey))
            {
                $newDir = [pscustomobject]@{ name = $p; path = $cursorKey; type = 'dir'; children = @(); omitted_counts = [pscustomobject]@{files = 0; dirs = 0 } }
                $cursor.children += , $newDir
                $map[$cursorKey] = $newDir
            }
            $cursor = $map[$cursorKey]
        }

        $files = $g.Group | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object
        $count = 0
        foreach ($f in $files)
        {
            if ($count -lt $MaxFilesPerDir)
            {
                $relPath = if ($dirRel) { "$dirRel/$f" } else { $f }
                $cursor.children += , ([pscustomobject]@{
                        name       = $f
                        path       = $relPath
                        type       = 'file'
                        size_bytes = if ($FileSizeMap.ContainsKey($relPath)) { $FileSizeMap[$relPath] } else { -1 }
                    })
                $count++
            }
            else
            {
                $cursor.omitted_counts.files++
            }
        }
    }

    return $node
}

function Build-AsciiTree
{
    param([Parameter(Mandatory)] $Tree)

    $lines = [List[string]]::new()

    function Write-TreeNode($node, $prefix)
    {
        $lines.Add("$prefix$($node.name)")
        if ($node.type -eq 'dir')
        {
            $children = @($node.children | Sort-Object { $_.type }, { $_.name })
            for ($i = 0; $i -lt $children.Count; $i++)
            {
                $last = ($i -eq $children.Count - 1)
                $pre = $prefix + ($last ? '└── ' : '├── ')
                $nextPrefix = $prefix + ($last ? '    ' : '│   ')
                Write-TreeNode $children[$i] $nextPrefix
            }
            if ($node.omitted_counts.files -gt 0)
            {
                $lines.Add("$prefix... ($($node.omitted_counts.files) files omitted)")
            }
        }
    }

    Write-TreeNode $Tree ''
    return ($lines -join "`n")
}

function Build-TreeDiagramCompact
{
    <#
    .SYNOPSIS
        Minimal, token-lean tree diagram for JSON embedding.

    .DESCRIPTION
        Renders a two-space indented, hyphen-bulleted hierarchy:
          name
            - child
              - file.ext
        Avoids box-drawing glyphs and repeated guide bars to reduce token variety in LLM contexts.
    #>
    param([Parameter(Mandatory)] $Tree)

    $lines = [List[string]]::new()

    function Write-Compact($node, [int]$depth)
    {
        if ($depth -eq 0)
        {
            $lines.Add("$($node.name)")
        }
        else
        {
            $indent = ('  ' * $depth)
            $lines.Add("$indent- $($node.name)")
        }

        if ($node.type -eq 'dir')
        {
            $children = @($node.children | Sort-Object { $_.type }, { $_.name })
            foreach ($c in $children)
            {
                Write-Compact $c ($depth + 1)
            }
            if ($node.omitted_counts.files -gt 0)
            {
                $indent = ('  ' * ($depth + 1))
                $lines.Add("$indent- ... ($($node.omitted_counts.files) files omitted)")
            }
        }
    }

    Write-Compact $Tree 0
    return ($lines -join "`n")
}

function Build-TocTree
{
    <#
    .SYNOPSIS
        Render a directory tree with inline tab-delimited metadata per file leaf.
    .DESCRIPTION
        Depth-level prefixes: '│   ' for non-last siblings, '    ' for last child.
        No branch chars (no ├──/└──). File nodes with an entry in OffsetMap append
        tab-separated shard_index (optional), row_offset, row_meta_end, row_content_begin, row_content_end after the name.
        Files absent from OffsetMap render as name only.
    #>
    param(
        [Parameter(Mandatory)] $Tree,
        [Parameter()] [hashtable]$OffsetMap = @{}
    )

    $lines = [List[string]]::new()

    function Write-TocNode($node, [string]$prefix)
    {
        if ($node.type -eq 'file')
        {
            $meta = if ($OffsetMap.ContainsKey($node.path)) { $OffsetMap[$node.path] } else { $null }
            if ($meta)
            {
                $tail = if ($meta.shard_index)
                {
                    "`t$($meta.shard_index)`t$($meta.row_offset)`t$($meta.row_meta_end)`t$($meta.row_content_begin)`t$($meta.row_content_end)"
                }
                else
                {
                    "`t$($meta.row_offset)`t$($meta.row_meta_end)`t$($meta.row_content_begin)`t$($meta.row_content_end)"
                }
                $lines.Add("$prefix$($node.name)$tail")
            }
            else
            {
                $lines.Add("$prefix$($node.name)")
            }
        }
        else
        {
            $lines.Add("$prefix$($node.name)")
            $children = @($node.children | Sort-Object { $_.type }, { $_.name })
            for ($i = 0; $i -lt $children.Count; $i++)
            {
                Write-TocNode $children[$i] ($prefix + '    ')
            }
            if ($node.omitted_counts.files -gt 0)
            {
                $lines.Add("$prefix    ... ($($node.omitted_counts.files) files omitted)")
            }
        }
    }

    Write-TocNode $Tree ''
    return ($lines -join "`n")
}

# ==================== GIT INTEGRATION ====================





# ==================== SNAPSHOT PATH HELPERS (shared) ====================

function Get-SnapshotPathParts
{
    <#
    .SYNOPSIS
        Parse a snapshot JSON path into reusable parts.

    .DESCRIPTION
        Returns an object with:
          - Directory: Directory containing the snapshot
          - BaseName:  File name without extension (e.g., repo_20250101_120000)
          - Stem:      Same as BaseName (kept for clarity and future flexibility)
          - Timestamp: Parsed 'yyyyMMdd_HHmmss' segment when present; otherwise empty
          - Parent:    The prefix before the timestamp underscore; equals BaseName when not found
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SnapshotJsonPath)

    $dir = Split-Path -Parent $SnapshotJsonPath
    $base = [IO.Path]::GetFileNameWithoutExtension($SnapshotJsonPath)
    $m = [regex]::Match($base, '_(\d{8}_\d{6})$')
    $ts = if ($m.Success) { $m.Groups[1].Value } else { '' }
    $parent = if ($m.Success) { $base.Substring(0, $base.Length - 1 - $ts.Length) } else { $base }

    return [pscustomobject]@{
        Directory = $dir
        BaseName  = $base
        Stem      = $base
        Timestamp = $ts
        Parent    = $parent
    }
}

function Get-SnapshotSiblingPath
{
    <#
    .SYNOPSIS
        Build a sibling artifact path next to a snapshot using a conventional suffix and extension.

    .PARAMETER SnapshotJsonPath
        The path to the snapshot JSON file.

    .PARAMETER Suffix
        Suffix to append to the stem (e.g., '_ngram', '_fltc', '-header').

    .PARAMETER Extension
        File extension without dot (e.g., 'jsonl', 'json', 'txt').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotJsonPath,
        [Parameter(Mandatory)][string]$Suffix,
        [Parameter(Mandatory)][string]$Extension
    )

    $parts = Get-SnapshotPathParts -SnapshotJsonPath $SnapshotJsonPath
    $name = "{0}{1}.{2}" -f $parts.Stem, $Suffix, $Extension
    return (Join-Path $parts.Directory $name)
}

function Get-SnapshotArtifactPaths
{
    <#
    .SYNOPSIS
        Return conventional artifact paths for a given encoder.

    .PARAMETER SnapshotJsonPath
        The path to the snapshot JSON file.

    .PARAMETER Encoder
        Encoder moniker (e.g., 'multires','fltc','ngram').

    .PARAMETER ShardHeader
        When true, includes a header path for sharded JSON header files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotJsonPath,
        [Parameter(Mandatory)][string]$Encoder,
        [switch]$ShardHeader
    )

    $jsonl = Get-SnapshotSiblingPath -SnapshotJsonPath $SnapshotJsonPath -Suffix ("_{0}" -f $Encoder) -Extension 'jsonl'
    $header = $null
    if ($ShardHeader)
    {
        $header = Get-SnapshotSiblingPath -SnapshotJsonPath $SnapshotJsonPath -Suffix ("_{0}-header" -f $Encoder) -Extension 'json'
    }

    return [pscustomobject]@{ jsonl = $jsonl; header = $header }
}


# ==================== MAIN PUBLIC FUNCTION ====================
function Get-RepoSnapshot
{

    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Path = '',
        [string]$OutputFile = '',
        [bool]$UseParallelism = $True,
        [int]$ThrottleLimit = 6,
        [int]$GitHistoryCount = 0,
        [int]$MaxFileSizeKB = 4096,
        [int]$MaxFileCount = 5000,
        [int]$MaxPreviewChars = 200,
        [int]$JsonDepth = 20,
        [bool]$StripComments = $False,
        [bool]$IncludeFileContent = $True,
        [bool]$IncludeFilePreviews = $False,
        [bool]$IncludeAsciiInJson = $False,
        [bool]$IncludeDirectoryStructureInJson = $False,
        [bool]$IncludePathsArray = $False,
        [bool]$ExportTree = $True,
        [bool]$FullTree = $False, # New: export full file+directory tree

        # [string[]]$IgnoreFilesToRespect = @(),
        [string]$NativeIgnoreFile = "",
        [bool]$UseParentIgnore = $True,
        [bool]$RespectGitIgnore = $True,

        [string[]]$IncludePatterns = @(), # "*.py","*.ps1","*.md","*sh"
        [string[]]$ExtraIncludePatterns = @(), #@("rs.core/*.psm1")
        [string[]]$ExcludePatterns = @(), # ".png",".git"
        [string[]]$ExtraExcludePatterns = @(".snapshot"), # @('*.md','*.cd','.snapshot/', '.snapignore/','.ignore/','.depr/','images/', 'venv/'), #, '*.json'

        [string[]]$ContentFilterInclude = @(),
        [string[]]$ContentFilterExclude = @(),

        [string]$TreeInstruction = $null,

        [bool]$OmitEmptyPreview = $True
    )


    $ErrorActionPreference = 'Stop'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Clamp JsonDepth to 0..100 as per ConvertTo-Json constraints in current pwsh
    # This shoudl be parametrized per PowerShell/ConvertToJson constraints e.g. "JsonDepth > $constraint is not allowed;"
    if ($JsonDepth -lt 0) { $JsonDepth = 0 }
    if ($JsonDepth -gt 100) { Write-Warning "JsonDepth > 100 is not allowed; clamping to 100"; $JsonDepth = 100 }

    if ([string]::IsNullOrWhiteSpace($Path))
    {
        $Path = (Get-Location).Path
        Write-Verbose "Resolved $Path as target directory..."
    }
    $rootPath = [IO.Path]::GetFullPath($Path)
    # Normalize once for consistent downstream relative calculations / matcher semantics
    $rootPath = Norm-Path -Path $rootPath
    if (-not (Test-Path $rootPath)) { throw "Root not found: $rootPath" }

    if ([string]::IsNullOrWhiteSpace($OutputFile))
    {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $pathLeaf = Split-Path -Leaf $rootPath
        $outputFileName = "${pathLeaf}_${timestamp}.json"
        $outputDir = Join-Path $rootPath ".snapshot"
        $OutputFile = Join-Path $outputDir $outputFileName
        Write-Verbose "Resolved default output $OutputFile..."
    }
    else
    {
        $outputDir = Split-Path -Parent $OutputFile
        if (-not $outputDir) { $outputDir = $rootPath }
    }

    if (-not (Test-Path -Path $outputDir))
    {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        Write-Verbose "Created output directory: $outputDir"
    }

    # Auto-detect optimal parallelism for PowerShell 7+
    if ($ThrottleLimit -le 0)
    {
        $cpuCount = [Environment]::ProcessorCount
        $ThrottleLimit = [Math]::Max(1, [Math]::Floor($cpuCount / 2))
        Write-Verbose "Auto-detected parallelism: $ThrottleLimit cores (CPU count: $cpuCount)"
    }

    # Discover external ignore rules
    Write-Verbose "Discovering external ignore rules..."
    $externalRules = if ([string]::IsNullOrWhiteSpace($NativeIgnoreFile)) { @() } else { Find-ExternalIgnoreRules -Root $rootPath -IgnoreFileName $NativeIgnoreFile -UseParentIgnore:$UseParentIgnore }
    Write-Verbose "Found $($externalRules.Count) external ignore rules"

    $externalMatcher = if ($externalRules.Count -gt 0) { Build-GitIgnoreMatcher -Rules $externalRules } else { { param($p, $d) $False } }

    # Enhanced file enumeration with directory-first exclusion
    Write-Verbose "Enumerating files with directory-first optimization..."

    $excludeDirectories = @()
    $excludeFilePatterns = @()

    # Derive potential directory prune list ONLY from user-supplied patterns (no hardcoded dirs)
    $allExcludePatterns = $ExcludePatterns + $ExtraExcludePatterns
    foreach ($pattern in $allExcludePatterns)
    {
        $p = $pattern.Trim()
        if (-not $p) { continue }

        # Normalize pattern to forward slashes for consistent parsing
        $pNorm = $p.Replace('\', '/')

        # Patterns that clearly target a directory (ending with '/' or '/**')
        if ($pNorm.EndsWith('/'))
        {
            $leaf = ($pNorm.TrimEnd('/') -split '/')[-1]
            if ($leaf -and $leaf -notmatch '[*?]') { $excludeDirectories += $leaf; continue }
        }
        elseif ($pNorm.EndsWith('/**'))
        {
            $trimmed = $pNorm.Substring(0, $pNorm.Length - 3) # remove '/**'
            $leaf = ($trimmed -split '/')[-1]
            if ($leaf -and $leaf -notmatch '[*?]') { $excludeDirectories += $leaf; continue }
        }
        elseif ($pNorm -match '^([^*?/]+)/(?:\*\*)?$')
        {
            # Simple dir form like 'foo/' or 'foo/**'
            $excludeDirectories += $matches[1]; continue
        }

        # Simple single-segment dir like '.mypy_cache' without trailing slash
        if ($pNorm -notmatch '[*/?]' -and $pNorm -ne '.')
        {
            $excludeDirectories += $pNorm
            continue
        }

        # Otherwise treat as a file/path wildcard pattern
        $excludeFilePatterns += $pattern
    }
    $excludeDirectories = $excludeDirectories | Where-Object { $_ } | Select-Object -Unique

    Write-Verbose "Directory exclusions: $($excludeDirectories -join ', ')"
    Write-Verbose "Pattern exclusions: $($excludeFilePatterns -join ', ')"

    $allFiles = Get-FilteredFiles -Root $rootPath -ExcludeDirectories $excludeDirectories -MaxFileCount $MaxFileCount

    if ($excludeFilePatterns.Count -gt 0)
    {
        $allFiles = $allFiles | Where-Object {
            $relativePath = $_.Substring($rootPath.Length).TrimStart('\', '/').Replace('\', '/')
            $shouldExclude = $False
            foreach ($pattern in $excludeFilePatterns)
            {
                if ($relativePath -like $pattern) { $shouldExclude = $True; break }
            }
            -not $shouldExclude
        }
    }

    Write-Verbose "Found $($allFiles.Count) files after directory-first optimization"

    if ($allFiles.Count -eq 0)
    {
        Write-Warning "No files found in $rootPath"
        $emptyHeader = [pscustomobject]@{
            export_date         = (Get-Date).ToString('o')
            root                = $rootPath
            file_count          = 0
            ps_version          = $PSVersionTable.PSVersion.ToString()
            parallel_processing = $UseParallelism
            max_parallelism     = $ThrottleLimit
            max_preview_chars   = $MaxPreviewChars
            version             = "2.7.1"
            execution_time_ms   = $sw.ElapsedMilliseconds
            json_depth          = $JsonDepth
            git_history         = @()
            tree_diagram        = ""
            filters             = [pscustomobject]@{
                include_patterns             = @($IncludePatterns)
                exclude_patterns             = @($ExcludePatterns)
                extra_ignore_patterns        = @($ExtraExcludePatterns)
                extra_include_patterns       = @($ExtraIncludePatterns)
                content_filter_include       = @($ContentFilterInclude)
                content_filter_exclude       = @($ContentFilterExclude)
                external_ignore_file         = $NativeIgnoreFile
                use_parent_ignore            = $UseParentIgnore
                respect_gitignore            = $RespectGitIgnore
                derived_directory_exclusions = @()
                exclude_file_patterns        = @()
                external_ignore_rule_count   = 0
                git_ignored_count            = 0
            }
            processing          = [pscustomobject]@{
                strip_comments        = $False
                include_file_content  = $IncludeFileContent
                include_file_previews = $IncludeFilePreviews
            }
        }
        $snapshotEmpty = [pscustomobject]@{
            header             = $emptyHeader
            DirectoryStructure = $null
            files              = @()
        }
        if ($PSCmdlet.ShouldProcess($OutputFile, "Write repository snapshot"))
        {
            $snapshotEmpty | ConvertTo-Json -Depth $JsonDepth | Set-Content -Path $OutputFile -Encoding UTF8
            Write-Host "Repository snapshot saved to: $OutputFile" -ForegroundColor Green
            return $OutputFile
        }
        else
        {
            Write-Host "Operation cancelled by user" -ForegroundColor Yellow
            return $null
        }
    }

    $allFiles = @($allFiles)
    $allDirs = @(Get-ChildItem -LiteralPath $rootPath -Recurse -Force -Directory | ForEach-Object { $_.FullName })

    $relFiles = @($allFiles | ForEach-Object { Resolve-RelPath -Root $rootPath -Path $_ })
    $relDirs = @($allDirs  | ForEach-Object { Resolve-RelPath -Root $rootPath -Path $_ })
    $relFiles = @($allFiles | ForEach-Object { Resolve-RelPath -Root $rootPath -Path $_ } | ForEach-Object { Norm-Path -Path $_ })
    $relDirs = @($allDirs  | ForEach-Object { Resolve-RelPath -Root $rootPath -Path $_ } | ForEach-Object { Norm-Path -Path $_ })

    # Git ignored set
    $gitIgnored = [HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($RespectGitIgnore -and $allFiles.Count -gt 0)
    {
        Write-Verbose "Running git check-ignore on $($relFiles.Count) files..."
        $gitIgnored = Get-GitIgnoredPaths -RepositoryRoot $rootPath -RelativePaths ($relFiles + $relDirs) -VerboseOutput:$($PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Verbose'))
        Write-Verbose "Git ignored $($gitIgnored.Count) paths"
    }

    # Build path inclusion tester
    Write-Verbose "Creating path inclusion tester..."
    Write-Verbose "Include patterns: $($IncludePatterns -join ', ')"
    Write-Verbose "Exclude patterns: $($ExcludePatterns -join ', ')"

    $includePath = New-PathInclusionTester -ExternalIgnoreMatcher $externalMatcher -ExtraExcludePatterns $ExtraExcludePatterns -ExtraIncludePatterns $ExtraIncludePatterns -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns -GitIgnoredPaths $gitIgnored

    if (-not $includePath -or -not ($includePath -is [scriptblock]))
    {
        $includePath = { param($RelativePath, $IsDirectory) $True }
    }

    # Filter files
    $keptFiles = [List[string]]::new()
    for ($i = 0; $i -lt $relFiles.Count; $i++)
    {
        $rel = $relFiles[$i]
        $abs = $allFiles[$i]
        if ($includePath.InvokeReturnAsIs($rel, $False))
        {
            $keptFiles.Add($abs)
        }
    }

    Write-Verbose "Processing $($keptFiles.Count) kept files"

    if ($keptFiles.Count -eq 0 -and $relFiles.Count -gt 0)
    {
        Write-Warning "No files passed inclusion filter. Sample paths checked:"
        $samplePaths = $relFiles | Select-Object -First 5
        foreach ($sample in $samplePaths) { Write-Warning "  - $sample" }
        Write-Warning "Include patterns: $($IncludePatterns -join ', ')"
        Write-Warning "Exclude patterns: $($ExcludePatterns -join ', ')"
    }

    # Process file entries
    $entries = [List[object]]::new()

    # What is the -gt 10 referring to? depth?
    if ($UseParallelism -and $keptFiles.Count -gt 10)
    {
        $cpuCount = [Environment]::ProcessorCount
        $baseThrottle = [Math]::Min($ThrottleLimit, $cpuCount)

        if ($keptFiles.Count -lt 100) { $throttle = [Math]::Max(2, [Math]::Min($baseThrottle, 4)) }
        elseif ($keptFiles.Count -lt 1000) { $throttle = [Math]::Max(2, $baseThrottle) }
        else { $throttle = [Math]::Max(4, [Math]::Min($baseThrottle, 12)) }

        Write-Verbose "Processing with $throttle parallel threads (PowerShell 7+ native parallelism)"

        # Parallel runspaces don't inherit module functions; capture body as string
        # and recreate as a local scriptblock inside each runspace.
        $normalizeFnStr = ${function:Normalize-FileContent}.ToString()

        $fileData = for ($i = 0; $i -lt $keptFiles.Count; $i++)
        {
            @{
                AbsPath = $keptFiles[$i]
                RelPath = Resolve-RelPath -Root $rootPath -Path $keptFiles[$i]
            }
        }

        $entries = $fileData | ForEach-Object -Parallel {
            $item = $_
            $absPath = $item.AbsPath
            $relPath = $item.RelPath
            $normalizeFn = [scriptblock]::Create($using:normalizeFnStr)

            $fi = [System.IO.FileInfo]::new($absPath)
            $size = $fi.Length

            # Binary detection
            $isBinary = $False
            if ($size -gt 0 -and $size -le 1024)
            {
                try
                {
                    $bytes = [System.IO.File]::ReadAllBytes($absPath)
                    $isBinary = ([Array]::IndexOf($bytes, 0) -ge 0)
                }
                catch { $isBinary = $True }
            }
            elseif ($size -gt 1024)
            {
                try
                {
                    $buffer = New-Object byte[] 4096
                    $fs = [System.IO.File]::OpenRead($absPath)
                    $bytesRead = $fs.Read($buffer, 0, 4096)
                    $fs.Close()
                    $isBinary = ([Array]::IndexOf($buffer[0..($bytesRead - 1)], 0) -ge 0)
                }
                catch { $isBinary = $True }
            }

            $content = ""
            $preview = ""

            $needRead = ($using:IncludeFileContent -or $using:IncludeFilePreviews)
            if ($needRead -and -not $isBinary -and $size -le ($using:MaxFileSizeKB * 1024))
            {
                try
                {
                    $raw = [System.IO.File]::ReadAllText($absPath, [System.Text.UTF8Encoding]::new($False))
                    # Apply optional line-level content filtering
                    $filtered = $raw
                    if (($using:ContentFilterInclude.Count -gt 0) -or ($using:ContentFilterExclude.Count -gt 0))
                    {
                        try { $filtered = Filter-Content -Content $raw -IncludeContentPatterns $using:ContentFilterInclude -ExcludeContentPatterns $using:ContentFilterExclude } catch { $filtered = $raw }
                    }
                    $filtered = & $normalizeFn -Content $filtered -RelPath $relPath -StripComments $using:StripComments
                    $result = & {
                        param($Content, $MaxPreviewChars, $IncludePreviews)

                        $processed = $Content

                        $pv = if ($IncludePreviews)
                        {
                            if ($processed.Length -le $MaxPreviewChars)
                            {
                                $processed
                            }
                            else
                            {
                                $headLen = [Math]::Min([Math]::Floor($MaxPreviewChars * 0.6), $processed.Length)
                                $tailLen = [Math]::Min($MaxPreviewChars - $headLen - 20, [Math]::Max(0, $processed.Length - $headLen - 20))
                                $head = $processed.Substring(0, $headLen)
                                $tail = if ($tailLen -gt 0) { $processed.Substring($processed.Length - $tailLen) } else { '' }
                                "$head`n<...omitted...>`n$tail"
                            }
                        }
                        else { "" }

                        @{ content = $processed; preview = $pv }
                    } $filtered $using:MaxPreviewChars $using:IncludeFilePreviews

                    # Only retain full content when explicitly requested
                    if ($using:IncludeFileContent) { $content = $result.content } else { $content = "" }
                    $preview = $result.preview
                }
                catch
                {
                    $content = ""
                    $preview = ""
                }
            }
            else
            {
                # Keep fields present but empty for schema stability; preview may still be produced if binary suppressed
                $content = ""
                $preview = if ($using:IncludeFilePreviews) { "" } else { "" }
            }

            # Metrics calculation
            $charCount = if ($content) { $content.Length } else { 0 }
            $wordCount = if ($content) { ($content -split '\s+').Count } else { 0 }
            $punctCount = if ($content) { [regex]::Matches($content, '\p{P}').Count } else { 0 }

            # Shannon entropy (per character)
            $entropy = 0.0
            $uniqueChars = 0
            if ($content -and $charCount -gt 0)
            {
                $freqs = @{}
                foreach ($c in $content.ToCharArray())
                {
                    if ($freqs.ContainsKey($c)) { $freqs[$c]++ } else { $freqs[$c] = 1 }
                }
                $uniqueChars = $freqs.Count
                foreach ($v in $freqs.Values)
                {
                    $p = $v / $charCount
                    if ($p -gt 0) { $entropy += -1 * $p * [Math]::Log($p, 2) }
                }
            }

            # Compression ratio (Kolmogorov complexity proxy)
            $compressionRatio = 1.0
            if ($content -and $charCount -gt 100)
            {
                try
                {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
                    $ms = [System.IO.MemoryStream]::new()
                    $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
                    $gz.Write($bytes, 0, $bytes.Length)
                    $gz.Close()
                    $compressedSize = $ms.Length
                    $compressionRatio = [Math]::Round($compressedSize / $bytes.Length, 4)
                }
                catch { }
            }

            # Whitespace ratio (formatting density)
            $whitespaceRatio = 0.0
            if ($content -and $charCount -gt 0)
            {
                $whitespaceCount = ([regex]::Matches($content, '\s')).Count
                $whitespaceRatio = [Math]::Round($whitespaceCount / $charCount, 4)
            }

            # Line length statistics (structural regularity)
            $lineLengthStats = @{ mean = 0; median = 0; std_dev = 0; max = 0 }
            if ($content -and $charCount -gt 0)
            {
                $lines = $content -split "`n"
                $lengths = @($lines | ForEach-Object { $_.Length })
                if ($lengths.Count -gt 0)
                {
                    $mean = ($lengths | Measure-Object -Average).Average
                    $sorted = $lengths | Sort-Object
                    $median = $sorted[[Math]::Floor($sorted.Count / 2)]
                    $variance = ($lengths | ForEach-Object { [Math]::Pow($_ - $mean, 2) } | Measure-Object -Average).Average
                    $stdDev = [Math]::Sqrt($variance)
                    $lineLengthStats = @{
                        mean    = [Math]::Round($mean, 2)
                        median  = $median
                        std_dev = [Math]::Round($stdDev, 2)
                        max     = ($lengths | Measure-Object -Maximum).Maximum
                    }
                }
            }

            [pscustomobject]@{
                path       = $relPath
                last_write = $fi.LastWriteTimeUtc.ToString('o')
                attributes = [pscustomobject]@{
                    binary            = $isBinary
                    size_bytes        = $size
                    char_count        = $charCount
                    word_count        = $wordCount
                    punctuation_count = $punctCount
                    unique_chars      = $uniqueChars
                    entropy           = [Math]::Round($entropy, 4)
                    compression_ratio = $compressionRatio
                    whitespace_ratio  = $whitespaceRatio
                    line_stats        = [pscustomobject]$lineLengthStats
                }
                preview    = $preview
                content    = $content
            }
        } -ThrottleLimit $throttle
    }
    else
    {
        Write-Verbose "Processing $($keptFiles.Count) files sequentially"
        for ($i = 0; $i -lt $keptFiles.Count; $i++)
        {
            $abs = $keptFiles[$i]
            $rel = Resolve-RelPath -Root $rootPath -Path $abs

            $fi = Get-Item -LiteralPath $abs
            $size = $fi.Length
            $isBinary = $False
            try { $isBinary = Test-IsBinaryFile -Path $abs } catch { $isBinary = $True }

            $content = ""
            $preview = ""

            $needRead = ($IncludeFileContent -or $IncludeFilePreviews)
            if ($needRead -and -not $isBinary -and $size -le ($MaxFileSizeKB * 1024))
            {
                try
                {
                    $raw = Get-Content -LiteralPath $abs -Raw
                    $filtered = $raw
                    if (($ContentFilterInclude.Count -gt 0) -or ($ContentFilterExclude.Count -gt 0))
                    {
                        try { $filtered = Filter-Content -Content $raw -IncludeContentPatterns $ContentFilterInclude -ExcludeContentPatterns $ContentFilterExclude } catch { $filtered = $raw }
                    }
                    # I guess non-whitespace logic is being applied here conditionally but partially duplicated because whitespace minification already occurred
                    $filtered = Normalize-FileContent -Content $filtered -RelPath $rel -StripComments $StripComments
                    $result = New-ContentAndPreview -Content $filtered -MaxPreviewChars $MaxPreviewChars
                    if ($IncludeFileContent) { $content = $result.content } else { $content = "" }
                    $preview = if ($IncludeFilePreviews) { $result.preview } else { "" }
                }
                catch
                {
                    $content = ""
                    $preview = ""
                }
            }
            else
            {
                $content = ""
                $preview = if ($IncludeFilePreviews) { "" } else { "" }
            }

            # NOTE: Metric calculations need not be coded twice, this should be pulled out and written once for reuse
            # Metrics calculation
            $charCount = if ($content) { $content.Length } else { 0 }
            $wordCount = if ($content) { ($content -split '\s+').Count } else { 0 }
            $punctCount = if ($content) { [regex]::Matches($content, '\p{P}').Count } else { 0 }

            # Shannon entropy (per character)
            $entropy = 0.0
            $uniqueChars = 0
            if ($content -and $charCount -gt 0)
            {
                $freqs = @{}
                foreach ($c in $content.ToCharArray())
                {
                    if ($freqs.ContainsKey($c)) { $freqs[$c]++ } else { $freqs[$c] = 1 }
                }
                $uniqueChars = $freqs.Count
                foreach ($v in $freqs.Values)
                {
                    $p = $v / $charCount
                    if ($p -gt 0) { $entropy += -1 * $p * [Math]::Log($p, 2) }
                }
            }

            # Compression ratio (Kolmogorov complexity proxy)
            $compressionRatio = 1.0
            if ($content -and $charCount -gt 100)
            {
                try
                {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
                    $ms = [System.IO.MemoryStream]::new()
                    $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
                    $gz.Write($bytes, 0, $bytes.Length)
                    $gz.Close()
                    $compressedSize = $ms.Length
                    $compressionRatio = [Math]::Round($compressedSize / $bytes.Length, 4)
                }
                catch { }
            }

            # Whitespace ratio (formatting density)
            $whitespaceRatio = 0.0
            if ($content -and $charCount -gt 0)
            {
                $whitespaceCount = ([regex]::Matches($content, '\s')).Count
                $whitespaceRatio = [Math]::Round($whitespaceCount / $charCount, 4)
            }

            # Line length statistics (structural regularity)
            $lineLengthStats = @{ mean = 0; median = 0; std_dev = 0; max = 0 }
            if ($content -and $charCount -gt 0)
            {
                $lines = $content -split "`n"
                $lengths = @($lines | ForEach-Object { $_.Length })
                if ($lengths.Count -gt 0)
                {
                    $mean = ($lengths | Measure-Object -Average).Average
                    $sorted = $lengths | Sort-Object
                    $median = $sorted[[Math]::Floor($sorted.Count / 2)]
                    $variance = ($lengths | ForEach-Object { [Math]::Pow($_ - $mean, 2) } | Measure-Object -Average).Average
                    $stdDev = [Math]::Sqrt($variance)
                    $lineLengthStats = @{
                        mean    = [Math]::Round($mean, 2)
                        median  = $median
                        std_dev = [Math]::Round($stdDev, 2)
                        max     = ($lengths | Measure-Object -Maximum).Maximum
                    }
                }
            }

            $entries.Add([pscustomobject]@{
                    path       = $rel
                    last_write = $fi.LastWriteTimeUtc.ToString('o')
                    attributes = [pscustomobject]@{
                        binary            = $isBinary
                        size_bytes        = $size
                        char_count        = $charCount
                        word_count        = $wordCount
                        punctuation_count = $punctCount
                        unique_chars      = $uniqueChars
                        entropy           = [Math]::Round($entropy, 4)
                        compression_ratio = $compressionRatio
                        whitespace_ratio  = $whitespaceRatio
                        line_stats        = [pscustomobject]$lineLengthStats
                    }
                    preview    = $preview
                    content    = $content
                })
        }
    }

    # Build directory structure and ASCII/compact trees
    $includedRel = @($entries | ForEach-Object { $_.path })
    if ($includedRel.Count -eq 0) { $includedRel = @() }

    $fileSizeMap = @{}
    foreach ($e in $entries) { $fileSizeMap[$e.path] = $e.attributes.size_bytes }

    $tree = $null
    $ascii = ""
    $compact = ""

    # Always compute for external export and compact JSON diagram
    $tree = Build-DirectoryTree -Root $rootPath -IncludedPaths $includedRel -MaxDepth 6 -MaxFilesPerDir 100 -FileSizeMap $fileSizeMap
    $ascii = Build-AsciiTree -Tree $tree
    $compact = Build-TreeDiagramCompact -Tree $tree

    # Build header (formerly metadata) with schema-stable git_history, filter + processing insight
    $header = [pscustomobject]@{
        export_date         = (Get-Date).ToString('o')
        root                = $rootPath
        file_count          = $entries.Count
        ps_version          = $PSVersionTable.PSVersion.ToString()
        parallel_processing = $UseParallelism
        max_parallelism     = $ThrottleLimit
        max_preview_chars   = $MaxPreviewChars
        version             = "2.7.1"
        execution_time_ms   = $sw.ElapsedMilliseconds
        json_depth          = $JsonDepth
        git_history         = @()
        tree_diagram        = $compact
        filters             = [pscustomobject]@{
            include_patterns             = @($IncludePatterns)
            exclude_patterns             = @($ExcludePatterns)
            extra_ignore_patterns        = @($ExtraExcludePatterns)
            extra_include_patterns       = @($ExtraIncludePatterns)
            content_filter_include       = @($ContentFilterInclude)
            content_filter_exclude       = @($ContentFilterExclude)
            external_ignore_file         = $NativeIgnoreFile
            use_parent_ignore            = $UseParentIgnore
            respect_gitignore            = $RespectGitIgnore
            derived_directory_exclusions = @($excludeDirectories)
            exclude_file_patterns        = @($excludeFilePatterns)
            external_ignore_rule_count   = $externalRules.Count
            git_ignored_count            = $gitIgnored.Count
        }
        processing          = [pscustomobject]@{
            strip_comments        = $StripComments
            include_file_content  = $IncludeFileContent
            include_file_previews = $IncludeFilePreviews
        }
    }

    # Add git history if requested
    if ($GitHistoryCount -gt 0)
    {
        $gitCmd = Get-Command git -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gitCmd)
        {
            Push-Location $rootPath
            try
            {
                $log = & $gitCmd.Path 'log' '-n' $GitHistoryCount "--pretty=format:%H|%an|%ad|%s" '--date=iso-strict' 2>$null
                if ($LASTEXITCODE -eq 0 -and $log)
                {
                    $gitHistoryArray = @(
                        $log -split "`n" | ForEach-Object {
                            $parts = $_ -split '\|', 4
                            if ($parts.Count -ge 4)
                            {
                                [pscustomobject]@{ hash = $parts[0]; author = $parts[1]; date = $parts[2]; subject = $parts[3] }
                            }
                        }
                    )
                    $header | Add-Member -NotePropertyName git_history -NotePropertyValue $gitHistoryArray -Force
                }
            }
            finally
            {
                Pop-Location
            }
        }
    }

    # Create snapshot object (tree_diagram already nested in header)
    # Capture raw invocation arguments for reproducibility (canonical: header.params)
    # Add reproducibility invocation parameters (must use Add-Member for new properties on [pscustomobject])
    $header | Add-Member -NotePropertyName params -NotePropertyValue ([pscustomobject]@{
            path                                = $Path
            output_file                         = $OutputFile
            use_parallelism                     = $UseParallelism
            throttle_limit                      = $ThrottleLimit
            git_history_count                   = $GitHistoryCount
            max_file_size_kb                    = $MaxFileSizeKB
            max_file_count                      = $MaxFileCount
            max_preview_chars                   = $MaxPreviewChars
            json_depth                          = $JsonDepth
            export_tree                         = $ExportTree
            strip_comments                      = $StripComments
            include_file_previews               = $IncludeFilePreviews
            include_file_content                = $IncludeFileContent
            include_ascii_in_json               = $IncludeAsciiInJson
            include_directory_structure_in_json = $IncludeDirectoryStructureInJson
            include_paths_array                 = $IncludePathsArray
            native_ignore_file                  = $NativeIgnoreFile
            use_parent_ignore                   = $UseParentIgnore
            respect_git_ignore                  = $RespectGitIgnore
            include_patterns                    = $IncludePatterns
            exclude_patterns                    = $ExcludePatterns
            extra_ignore_patterns               = $ExtraExcludePatterns
        }) -Force

    # Boolean / flag summary for quick scanning (stable surface)
    # Add lightweight flags summary (Add-Member to avoid assignment exception)
    $header | Add-Member -NotePropertyName flags -NotePropertyValue ([pscustomobject]@{
            parallel            = $UseParallelism
            export_tree         = $ExportTree
            include_ascii       = $IncludeAsciiInJson
            include_dir_struct  = $IncludeDirectoryStructureInJson
            include_paths_array = $IncludePathsArray
            include_content     = $IncludeFileContent
            include_previews    = $IncludeFilePreviews
            strip_comments      = $StripComments
        }) -Force

    $snapshot = [pscustomobject]@{
        header = $header
        files  = $entries
    }

    if ($IncludeDirectoryStructureInJson)
    {
        Add-Member -InputObject $snapshot -NotePropertyName DirectoryStructure -NotePropertyValue $tree
    }

    if ($IncludeAsciiInJson)
    {
        Add-Member -InputObject $snapshot -NotePropertyName AsciiTree -NotePropertyValue $ascii
    }

    if ($IncludePathsArray)
    {
        Add-Member -InputObject $snapshot -NotePropertyName paths -NotePropertyValue $includedRel
    }

    $sw.Stop()
    Write-Host "RepoSnapshot v2.7.1 completed in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green

    # Handle output
    if ($PSCmdlet.ShouldProcess($OutputFile, "Write repository snapshot"))
    {
        # Build envelope from all $snapshot properties except files[]
        $envelope = [ordered]@{}
        foreach ($prop in $snapshot.PSObject.Properties)
        {
            if ($prop.Name -ne 'files') { $envelope[$prop.Name] = $prop.Value }
        }
        $envelopeJson = ([pscustomobject]$envelope | ConvertTo-Json -Depth $JsonDepth -Compress)

        $enc = [System.Text.UTF8Encoding]::new($false)
        $fs = [System.IO.FileStream]::new($OutputFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 65536)
        $writer = [System.IO.StreamWriter]::new($fs, $enc, 65536)

        # Write opening JSON fragment (everything except the files array)
        $writer.Write($envelopeJson.Substring(0, $envelopeJson.Length - 1))
        $writer.Write(',"files":[')
        $writer.Flush()

        $tocEntries = [System.Collections.Generic.List[pscustomobject]]::new()
        $firstEntry = $true
        $entries = @($entries | Sort-Object { $_.path })
        foreach ($entry in $entries)
        {
            if (-not $firstEntry) { $writer.Write(',') }
            $firstEntry = $false
            $writer.Flush()
            $byteOffset = $fs.Position
            $entryToWrite = if ($OmitEmptyPreview -and [string]::IsNullOrEmpty($entry.preview)) { $entry | Select-Object -Property * -ExcludeProperty preview } else { $entry }
            $entryJson = $entryToWrite | ConvertTo-Json -Depth $JsonDepth -Compress
            $offsets = Get-EntryByteOffsets -EntryJson $entryJson -BaseOffset $byteOffset
            $writer.Write($entryJson)
            $tocEntries.Add([pscustomobject]@{
                    path              = $entry.path
                    row_offset        = $offsets.row_offset
                    row_meta_end      = $offsets.row_meta_end
                    row_content_begin = $offsets.row_content_begin
                    row_content_end   = $offsets.row_content_end
                })
        }

        $writer.Write(']}')
        $writer.Flush()
        $writer.Close()
        $fs.Dispose()

        Write-Host "Repository snapshot saved to: $OutputFile" -ForegroundColor Green

        # Export coordinated tree file
        if ($ExportTree)
        {
            $treeFile = $OutputFile -replace '\.json$', '_tree.md'
            $treeStem = [IO.Path]::GetFileNameWithoutExtension($OutputFile)

            $treeOffsetMap = @{}
            foreach ($toc in $tocEntries)
            {
                $treeOffsetMap[$toc.path] = @{
                    shard_index       = $null
                    row_offset        = $toc.row_offset
                    row_meta_end      = $toc.row_meta_end
                    row_content_begin = $toc.row_content_begin
                    row_content_end   = $toc.row_content_end
                }
            }

            $tocTree = Build-TocTree -Tree $tree -OffsetMap $treeOffsetMap
            if (-not (Import-TocTemplateEngine)) { throw "Could not load TOC template engine." }

            $model = New-SnapshotTocModel -TreeStem $treeStem -TreeFile $treeFile -TocTree $tocTree
            $rendered = Expand-TocTemplate -Model $model
            $rendered | Set-Content -LiteralPath $treeFile -Encoding UTF8
            Write-Host "Tree exported to: $treeFile" -ForegroundColor Cyan
        }

        return $OutputFile
    }
    else
    {
        Write-Host "Operation cancelled by user" -ForegroundColor Yellow
        return $null
    }
}

#region Helper Functions

function Shard-SnapshotFile
{

    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [int]$MaxShardSizeKB = 2048,

        [long]$MaxShardSpanBytes = 0,

        [ValidateSet('FileLevel', 'ContentBased', 'FixedSize', 'Auto')]
        [string]$Strategy = 'Auto',

        [ValidateSet('Flat', 'ByFileType', 'ByRootDirectory')]
        [string]$GroupingStrategy = 'Flat',

        [ValidateSet('Greedy', 'Balanced', 'Loose')]
        [string]$PackingStrategy = 'Greedy',

        [switch]$AllowOversizedShards = $true,

        [string]$ShardOutputDirectory = '',

        [string[]]$ExcludeShardBlocks = @(),

        [bool]$ExcludeShardMetadata = $false,

        [bool]$OmitEmptyPreview = $True,

        [bool]$ExcludeAttributes = $false
    )

    function Resolve-InputFile
    {
        param([Parameter(Mandatory)][string]$Path)
        $candidate = $Path
        if (-not (Test-Path -LiteralPath $candidate))
        {
            $tryJson = "$candidate.json"
            if (Test-Path -LiteralPath $tryJson)
            {
                return Get-Item -LiteralPath $tryJson
            }
            else
            {
                throw "Input file not found: $Path (also tried $tryJson)"
            }
        }
        Get-Item -LiteralPath $candidate
    }

    function Measure-LogicalJsonSizeBytes
    {
        param([Parameter(Mandatory)][object]$Record, [int]$Depth = 10)
        $json = $Record | ConvertTo-Json -Depth $Depth -Compress
        [Text.Encoding]::UTF8.GetByteCount($json)
    }

    function Get-PathParts
    {
        param([Parameter(Mandatory)][string]$FilePath)

        $dir = Split-Path -Parent $FilePath
        $base = [IO.Path]::GetFileNameWithoutExtension($FilePath)
        $m = [regex]::Match($base, '_(\d{8}_\d{6})$')
        $ts = if ($m.Success) { $m.Groups[1].Value } else { '' }
        $parent = if ($m.Success) { $base.Substring(0, $base.Length - 1 - $ts.Length) } else { $base }

        [pscustomobject]@{
            Directory = $dir
            BaseName  = $base
            Stem      = $base
            Timestamp = $ts
            Parent    = $parent
        }
    }

    #endregion

    # Resolve input file with robust error handling
    $inputFile = Resolve-InputFile -Path $Path
    Write-Host "📁 Processing: $($inputFile.Name)" -ForegroundColor Green

    # Load snapshot
    Write-Host "📄 Loading snapshot..." -ForegroundColor Cyan
    $snapshot = Get-Content $inputFile.FullName -Raw | ConvertFrom-Json
    $originalCount = $snapshot.files.Count


    # Auto-detect strategy
    if ($Strategy -eq 'Auto')
    {
        $Strategy = if ($snapshot.files.Count -gt 1000) { 'ContentBased' }
        elseif ($snapshot.files.Count -gt 100) { 'FileLevel' }
        else { 'FixedSize' }
    }

    # Parse path parts for output naming
    $pathParts = Get-PathParts -FilePath $inputFile.FullName
    $outputDir = $pathParts.Directory
    if (-not [string]::IsNullOrWhiteSpace($ShardOutputDirectory)) {
        $outputDir = [IO.Path]::GetFullPath($ShardOutputDirectory)
    }
    $newTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $maxSpan = if ($MaxShardSpanBytes -gt 0) { $MaxShardSpanBytes } else { [long]$MaxShardSizeKB * 1024L }
    $enc = [System.Text.UTF8Encoding]::new($false)
    $includeAttributes = -not ($ExcludeAttributes -or ($ExcludeShardBlocks -contains 'Attributes'))
    $schemaRow = if ($includeAttributes) {
        "idx<int> | path<str> | attributes:{char_count<int> word_count<int> whitespace_ratio<float> entropy<float>} | length<int> | content<str> |"
    }
    else {
        "idx<int> | path<str> | length<int> | content<str> |"
    }
    $schemaBytes = [long]($enc.GetByteCount($schemaRow) + 1)

    Write-Host "✂️  Creating shards using $Strategy strategy, grouping $GroupingStrategy, packing $PackingStrategy..." -ForegroundColor Green

    # Phase 1: render every row into a flat in-memory buffer, recording exact
    # byte offsets as we go.  Running $bytePos avoids any O(N²) re-encoding.
    $sb = [System.Text.StringBuilder]::new(4 * 1024 * 1024)
    $rowManifest = [System.Collections.Generic.List[pscustomobject]]::new()
    $bytePos = 0L

    $schemaLine = "$schemaRow`n"
    [void]$sb.Append($schemaLine)
    $bytePos += $enc.GetByteCount($schemaLine)

    $sortedFiles = [System.Linq.Enumerable]::OrderBy(
        [System.Collections.Generic.IEnumerable[object]]$snapshot.files,
        [Func[object, string]] { param($f) [string]$f.path }
    )

    $tempIdx = 0
    foreach ($file in $sortedFiles)
    {
        $cc = [int]$file.attributes.char_count
        $wc = [int]$file.attributes.word_count
        $wsr = ([double]$file.attributes.whitespace_ratio).ToString("0.0000")
        $ent = ([double]$file.attributes.entropy).ToString("0.0000")
        if ([string]::IsNullOrEmpty($file.content)) { $esc = "" }
        else
        {
            $cj = $file.content | ConvertTo-Json -Compress
            $esc = $cj.Substring(1, $cj.Length - 2)
        }
        $len = $enc.GetByteCount($esc)

        $line = if ($includeAttributes) { "$tempIdx | $($file.path) | {$cc $wc $wsr $ent} | $len | $esc |`n" } else { "$tempIdx | $($file.path) | $len | $esc |`n" }
        $rowBytes = $enc.GetByteCount($line)

        $rowManifest.Add([pscustomobject]@{
                Idx          = $tempIdx
                OrigFile     = $file
                RelativePath = $file.path
                Escaped      = $esc
                Length       = $len
                CharCount    = $cc
                WordCount    = $wc
                WsRatio      = $wsr
                Entropy      = $ent
                ByteStart    = $bytePos
                ByteSpan     = $rowBytes
                Content      = $file.content
                ShardOffset  = 0
            })

        [void]$sb.Append($line)
        $bytePos += $rowBytes
        $tempIdx++
    }

    $schemaBytes_arr = $enc.GetBytes($schemaLine)

    $excludeShardBlocks = @()
    if ($ExcludeShardBlocks) { $excludeShardBlocks += $ExcludeShardBlocks }
    if ($ExcludeShardMetadata) { $excludeShardBlocks += 'Metadata' }
    $excludeShardBlocks = @($excludeShardBlocks | Where-Object { $_ -and $_ -ne '' })
    $writeMetadataBlock = -not ($excludeShardBlocks -contains 'Metadata')

    $shards = [System.Collections.Generic.List[System.Collections.Generic.List[pscustomobject]]]::new()
    $fullBytes = $null

    if ($GroupingStrategy -ne 'Flat')
    {
        if (-not (Get-Command Partition-Files -ErrorAction SilentlyContinue))
        {
            throw "Partition-Files is not available. Ensure rs.lts.sharding is imported."
        }

        $partitionResult = Partition-Files -Files $rowManifest -MaxFilesPerShard 100000 -MaxShardSizeKB $MaxShardSizeKB -MaxShardSpanBytes $MaxShardSpanBytes -GroupingStrategy $GroupingStrategy -PackingStrategy $PackingStrategy -AllowOversizedShards:$AllowOversizedShards
        foreach ($shard in $partitionResult.Shards)
        {
            $shardList = [System.Collections.Generic.List[pscustomobject]]::new()
            foreach ($item in $shard.Files)
            {
                if (-not $item.PSObject.Properties['GroupKey'])
                {
                    $item | Add-Member -NotePropertyName GroupKey -NotePropertyValue $shard.GroupKey -Force
                }
                $shardList.Add($item)
            }
            $shards.Add($shardList)
        }
    }
    else
    {
        # Phase 2: compute shard cut points as byte cursor positions.
        # A row that alone exceeds $maxSpan opens its own shard (no fragmentation).
        $shardCuts = [System.Collections.Generic.List[long]]::new()
        $shardCuts.Add($schemaBytes)

        foreach ($entry in $rowManifest)
        {
            $shardStart = $shardCuts[$shardCuts.Count - 1]
            if (($entry.ByteStart - $shardStart) + $entry.ByteSpan -gt $maxSpan -and
                $entry.ByteStart -gt $shardStart)
            {
                $shardCuts.Add($entry.ByteStart)
            }
        }
        $shardCuts.Add($bytePos)   # sentinel

        # Materialise byte array once for slicing
        $fullBytes = $enc.GetBytes($sb.ToString())

        # Phase 3: build shard row-membership index by iterating $rowManifest and
        # checking entry.ByteStart >= cutStart && entry.ByteStart < cutEnd per window.
        for ($si = 0; $si -lt ($shardCuts.Count - 1); $si++)
        {
            $cutStart = $shardCuts[$si]
            $cutEnd = $shardCuts[$si + 1]
            $binRows = [System.Collections.Generic.List[pscustomobject]]::new()
            foreach ($entry in $rowManifest)
            {
                if ($entry.ByteStart -ge $cutStart -and $entry.ByteStart -lt $cutEnd)
                {
                    $binRows.Add($entry)
                }
            }
            $shards.Add($binRows)
        }
    }

    if (-not (Test-Path -Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        Write-Verbose "Created shard output directory: $outputDir"
    }

    $results = @()
    $offsetMap = @{}
    Write-Host "`n📦 Writing $($shards.Count) shard file(s)..." -ForegroundColor Cyan

    for ($i = 0; $i -lt $shards.Count; $i++)
    {
        $shardIndex = $i + 1
        $shardLabel = "s{0:D3}" -f $shardIndex
        if ($GroupingStrategy -ne 'Flat') {
            $groupName = $shards[$i][0].GroupKey
            if ($groupName -eq '.root' -or [string]::IsNullOrEmpty($groupName)) {
                $shardPath = Join-Path $outputDir ("{0}_s{1:D3}.txt" -f $pathParts.Stem, $shardIndex)
            }
            else {
                $groupToken = ($groupName -replace '[\\/]+', '_') -replace '[^A-Za-z0-9_-]', '_'
                $shardPath = Join-Path $outputDir ("{0}_{1}_{2}.txt" -f $pathParts.Stem, $shardLabel, $groupToken)
            }
        }
        else {
            $shardPath = Join-Path $outputDir ("{0}_s{1:D3}.txt" -f $pathParts.Stem, $shardIndex)
        }

        if ($GroupingStrategy -ne 'Flat')
        {
            $fs = [System.IO.File]::Open($shardPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try
            {
                if ($writeMetadataBlock)
                {
                    $fs.Write($schemaBytes_arr, 0, $schemaBytes_arr.Length)
                    $shardHeaderBytes = [long]$schemaBytes_arr.Length
                }
                else
                {
                    $shardHeaderBytes = 0
                }

                $rows = $shards[$i]
                $currentOffset = $shardHeaderBytes

                foreach ($row in $rows)
                {
                    $lineBytes = if ($includeAttributes) { $enc.GetBytes("$($row.Idx) | $($row.OrigFile.path) | {$($row.CharCount) $($row.WordCount) $($row.WsRatio) $($row.Entropy)} | $($row.Length) | $($row.Escaped)`n") } else { $enc.GetBytes("$($row.Idx) | $($row.OrigFile.path) | $($row.Length) | $($row.Escaped)`n") }
                    $fs.Write($lineBytes, 0, $lineBytes.Length)
                    $row.ShardOffset = $currentOffset
                    $currentOffset += $lineBytes.Length
                }
            }
            finally
            {
                $fs.Close()
            }

            $shardSize = (Get-Item -LiteralPath $shardPath).Length
        }
        else
        {
            $cutStart = $shardCuts[$i]
            $cutLen = [int]($shardCuts[$i + 1] - $cutStart)
            if ($writeMetadataBlock)
            {
                $chunk = [byte[]]::new($schemaBytes_arr.Length + $cutLen)
                [System.Buffer]::BlockCopy($schemaBytes_arr, 0, $chunk, 0, $schemaBytes_arr.Length)
                [System.Buffer]::BlockCopy($fullBytes, [int]$cutStart, $chunk, $schemaBytes_arr.Length, $cutLen)
                $shardHeaderBytes = [long]$schemaBytes_arr.Length
            }
            else
            {
                $chunk = [byte[]]::new($cutLen)
                [System.Buffer]::BlockCopy($fullBytes, [int]$cutStart, $chunk, 0, $cutLen)
                $shardHeaderBytes = 0
            }

            [System.IO.File]::WriteAllBytes($shardPath, $chunk)

            # Build offset map entries for this shard's rows
            $rows = $shards[$i]
            $shardSize = $chunk.Length
        }
        foreach ($row in $rows)
        {
            $localOffset = if ($GroupingStrategy -ne 'Flat') { $row.ShardOffset } else { $shardHeaderBytes + ($row.ByteStart - $cutStart) }
            $metaPrefix = if ($includeAttributes) { "$($row.Idx) | $($row.OrigFile.path) | {$($row.CharCount) $($row.WordCount) $($row.WsRatio) $($row.Entropy)} | $($row.Length)" } else { "$($row.Idx) | $($row.OrigFile.path) | $($row.Length)" }
            $fullPrefix = "$metaPrefix | "
            $rowMetaEnd = $localOffset + $enc.GetByteCount($metaPrefix) - 1
            $rowContentBegin = $localOffset + $enc.GetByteCount($fullPrefix)
            $rowContentEnd = if ($row.Length -gt 0) { $rowContentBegin + $row.Length - 1 } else { $rowContentBegin }

            $offsetMap[$row.OrigFile.path] = @{
                shard_index       = $shardLabel
                row_offset        = $localOffset
                row_meta_end      = $rowMetaEnd
                row_content_begin = $rowContentBegin
                row_content_end   = $rowContentEnd
            }
        }

        $results += [PSCustomObject]@{
            Index  = $shardIndex
            Path   = $shardPath
            SizeKB = [Math]::Round($shardSize / 1024, 2)
            Files  = $rows.Count
        }

        Write-Host "  ✓ Shard $shardIndex`: $($rows.Count) files, $([Math]::Round($shardSize/1024,2)) KB" -ForegroundColor Gray
    }

    Write-Host "`n📋 Sharding Summary:" -ForegroundColor Green
    $results | Format-Table Index, @{n = 'Size (KB)'; e = { $_.SizeKB }; f = 'N2' }, Files, @{n = 'Filename'; e = { Split-Path $_.Path -Leaf } } -AutoSize

    # Generate unified tree file across all shards
    $treeFile = Join-Path $outputDir "$($pathParts.Stem)_tree.md"
    $snapshotRoot = if ($snapshot.header.root) { $snapshot.header.root } else { $pathParts.Directory }
    $allPaths = @($snapshot.files | ForEach-Object { $_.path })
    $fileSizeMap = @{}
    foreach ($f in $snapshot.files) { $fileSizeMap[$f.path] = $f.attributes.size_bytes }

    $tocTree = Build-TocTree -Tree (Build-DirectoryTree -Root $snapshotRoot -IncludedPaths $allPaths -FileSizeMap $fileSizeMap) -OffsetMap $offsetMap

    $groupLabel = if ($GroupingStrategy -ne 'Flat') { "Grouping: $GroupingStrategy | Packing: $PackingStrategy | " } else { '' }
    $spanLabel = if ($MaxShardSpanBytes -gt 0) { "MaxShardSpanBytes: $MaxShardSpanBytes" } else { "MaxShardSizeKB: $MaxShardSizeKB" }
    $summaryLine = "Strategy: $Strategy | $groupLabel$spanLabel | Created: $newTimestamp | Shards: $($results.Count)"

    if (-not (Import-TocTemplateEngine)) { throw "Could not load TOC template engine." }

    $model = New-ShardedTocModel `
        -PathParts $pathParts `
        -TreeFile $treeFile `
        -Results $results `
        -SummaryLine $summaryLine `
        -TocTree $tocTree `
        -WriteMetadataBlock $writeMetadataBlock `
        -ExcludedShardBlocks $excludeShardBlocks
    $rendered = Expand-TocTemplate -Model $model
    $rendered | Set-Content -LiteralPath $treeFile -Encoding UTF8
    Write-Host "Tree exported to: $treeFile" -ForegroundColor Cyan

    return $results
}

function Get-ShardedRepoSnapshot
{

    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [string[]]$ExtraExcludePatterns = @(),

        [bool]$StripComments = $False,

        [bool]$IncludeFileContent = $True,

        [int]$MaxShardSizeKB = 2048,

        [long]$MaxShardSpanBytes = 0,

        [ValidateSet('FileLevel', 'FixedSize', 'Auto')]
        [string]$Strategy = 'Auto',

        [ValidateSet('Flat', 'ByFileType', 'ByRootDirectory')]
        [string]$GroupingStrategy = 'Flat',

        [ValidateSet('Greedy', 'Balanced', 'Loose')]
        [string]$PackingStrategy = 'Greedy',

        [switch]$AllowOversizedShards = $true,

        [string]$OutputFile = '',
        [string]$ShardOutputDirectory = '',

        [string[]]$ExcludeShardBlocks = @(),

        [bool]$ExcludeShardMetadata = $false,

        [bool]$ExcludeAttributes = $false

    )

    $redirecting = -not [string]::IsNullOrWhiteSpace($ShardOutputDirectory)

    if ($redirecting)
    {
        # Redirected run: the entire run lands in $ShardOutputDirectory and the target's
        # .snapshot directory is never created. The intermediate JSON is only a transient
        # handoff to Shard-SnapshotFile; when we auto-name it we remove it after sharding,
        # leaving just the NDSON shards + tree. An explicit -OutputFile is honored and kept.
        $outDir = [IO.Path]::GetFullPath($ShardOutputDirectory)
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

        $autoTransient = [string]::IsNullOrWhiteSpace($OutputFile)
        $transient = if ($autoTransient)
        {
            $leaf = Split-Path -Leaf ([IO.Path]::GetFullPath($Path))
            Join-Path $outDir ("{0}_{1}.json" -f $leaf, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        }
        else { $OutputFile }

        $jsonPath = Get-RepoSnapshot -Path $Path -OutputFile $transient -ExportTree:$false -ExtraExcludePatterns $ExtraExcludePatterns -StripComments $StripComments -IncludeFileContent $IncludeFileContent
        try
        {
            return Shard-SnapshotFile -Path $jsonPath -MaxShardSizeKB $MaxShardSizeKB -MaxShardSpanBytes $MaxShardSpanBytes -Strategy $Strategy -GroupingStrategy $GroupingStrategy -PackingStrategy $PackingStrategy -AllowOversizedShards:$AllowOversizedShards -ShardOutputDirectory $ShardOutputDirectory -ExcludeShardBlocks $ExcludeShardBlocks -ExcludeShardMetadata:$ExcludeShardMetadata -ExcludeAttributes:$ExcludeAttributes
        }
        finally
        {
            if ($autoTransient -and $jsonPath -and (Test-Path -LiteralPath $jsonPath -PathType Leaf))
            {
                Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Default (un-redirected) behavior: snapshot JSON + shards + tree land in the target's .snapshot subdir.
    $snapshot = Get-RepoSnapshot -Path $Path -OutputFile $OutputFile -ExtraExcludePatterns $ExtraExcludePatterns -StripComments $StripComments -IncludeFileContent $IncludeFileContent
    return Shard-SnapshotFile -Path $snapshot -MaxShardSizeKB $MaxShardSizeKB -MaxShardSpanBytes $MaxShardSpanBytes -Strategy $Strategy -GroupingStrategy $GroupingStrategy -PackingStrategy $PackingStrategy -AllowOversizedShards:$AllowOversizedShards -ShardOutputDirectory $ShardOutputDirectory -ExcludeShardBlocks $ExcludeShardBlocks -ExcludeShardMetadata:$ExcludeShardMetadata -ExcludeAttributes:$ExcludeAttributes
}


# ==================== MODULE EXPORTS ====================

Set-Alias -Name rs -Value Get-RepoSnapshot
Export-ModuleMember -Function @(
    'Get-RepoSnapshot',
    'Shard-SnapshotFile',
    'Get-ShardedRepoSnapshot',
    'Get-SnapshotPathParts',
    'Get-SnapshotSiblingPath',
    'Get-SnapshotArtifactPaths',
    'Normalize-FileContent',
    'Filter-Content'
)
