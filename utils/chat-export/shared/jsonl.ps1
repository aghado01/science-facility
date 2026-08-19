# chat-export/shared/jsonl.ps1 — Client-agnostic JSONL snapshot and exchange IR I/O
#
# Live-file snapshot uses ReadWrite|Delete sharing and drops an incomplete JSON
# tail. Exchange envelopes are written as canonical JSONL plus a .jidx.

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\..\jso-jackson\jso-jackson.ps1"

function ConvertFrom-ChatJsonString
{
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -isnot [string]) { return $Value }
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }

    try { return ($Value | ConvertFrom-Json -Depth 100 -NoEnumerate) }
    catch { return $Value }
}

function New-ChatJsonlSnapshot
{
    <#
    .SYNOPSIS
        Snapshot an actively appended JSONL file and build its .jidx.
    .DESCRIPTION
        The source may still be open for append. This reader uses
        FileShare.ReadWrite|Delete, then drops an incomplete JSON tail if the
        snapshot races an in-progress write.
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
        throw "JSONL source not found: $SourcePath"
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

function Export-ChatExchanges
{
    <#
    .SYNOPSIS
        Write one canonical JSONL record per exchange envelope and build a .jidx.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Exchanges,

        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [Parameter(Mandatory)]
        [string]$Identity,

        [string]$OutputPrefix = 'thread'
    )

    $exchangeDir = [System.IO.Path]::Combine($WorkingDir, 'exchanges')
    [void][System.IO.Directory]::CreateDirectory($exchangeDir)
    $path = [System.IO.Path]::Combine(
        $exchangeDir, "$OutputPrefix-$Identity.jsonl")
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

function Resolve-ChatRunDir
{
    <#
    .SYNOPSIS
        Resolve a relocatable working root plus a UTC runstamp subdirectory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDir,

        [string]$RunStamp
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($WorkingDir)
    if ([string]::IsNullOrWhiteSpace($RunStamp))
    {
        $RunStamp = Get-JobTimestamp
    }
    if ($RunStamp -notmatch '^[0-9]{8}_[0-9]{6}$')
    {
        throw "Malformed run stamp '$RunStamp'. Expected UTC yyyyMMdd_HHmmss."
    }

    $runDir = [System.IO.Path]::Combine($resolvedRoot, $RunStamp)
    [void][System.IO.Directory]::CreateDirectory($runDir)
    return [pscustomobject]@{
        WorkingDir = $resolvedRoot
        RunStamp   = $RunStamp
        RunDir     = $runDir
    }
}

function Resolve-ChatMarkdownPath
{
    <#
    .SYNOPSIS
        Choose the Markdown deliverable path without embedding client defaults.
    #>
    [CmdletBinding()]
    param(
        [string]$MarkdownPath,
        [string]$MarkdownDir,
        [Parameter(Mandatory)]
        [string]$RunDir,
        [Parameter(Mandatory)]
        [string]$OutputPrefix,
        [Parameter(Mandatory)]
        [string]$Identity
    )

    $fileName = "$OutputPrefix-$Identity.md"
    if ($MarkdownPath)
    {
        return [System.IO.Path]::GetFullPath($MarkdownPath)
    }
    if ($MarkdownDir)
    {
        return [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine($MarkdownDir, $fileName))
    }
    if ($env:JSO_EXPORT_DIR)
    {
        return [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine($env:JSO_EXPORT_DIR, $fileName))
    }
    return [System.IO.Path]::Combine($RunDir, 'output', $fileName)
}
