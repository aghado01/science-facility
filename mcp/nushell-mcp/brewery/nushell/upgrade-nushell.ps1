<#
.SYNOPSIS
    Queries GitHub for the latest Nushell release, programmatically updates pin.json,
    and materializes the complete distribution into deps/nushell.

.DESCRIPTION
    1. Queries GitHub API for the latest release (or requested version).
    2. Downloads and verifies the OS-appropriate distribution archive.
    3. Programmatically updates brewery/nushell/pin.json with new platform artifact hashes.
    4. Deploys the complete release (engine, plugins, and tools) into deps/nushell.
    5. Writes restore-receipt.json and executes smoke tests.

.PARAMETER Version
    Specific version tag to upgrade to (defaults to latest release on GitHub).

.PARAMETER Force
    Force re-download and reinstall even if already installed.

.PARAMETER SkipTests
    Skip running the test suite after installation.

.PARAMETER NoPinUpdate
    Install without modifying pin.json.

.PARAMETER DryRun
    Check for latest release and preview changes without modifying files.

.PARAMETER TargetDir
    Custom destination path (defaults to deps/nushell).
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$Force,
    [switch]$SkipTests,
    [switch]$NoPinUpdate,
    [switch]$DryRun,
    [string]$TargetDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HostPlatformKey {
    $os = 'unknown'
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if ($IsWindows) { $os = 'windows' }
        elseif ($IsLinux) { $os = 'linux' }
        elseif ($IsMacOS) { $os = 'darwin' }
    } else {
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $os = 'windows'
        } elseif ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix) {
            $os = if ((uname) -match 'Darwin') { 'darwin' } else { 'linux' }
        }
    }

    $arch = 'x64'
    try {
        $rawArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
        if ($rawArch -in @('x64', 'amd64')) {
            $arch = 'x64'
        } elseif ($rawArch -in @('arm64', 'aarch64')) {
            $arch = 'arm64'
        } else {
            $arch = $rawArch
        }
    } catch {
        if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') {
            $arch = 'arm64'
        } elseif ($env:PROCESSOR_ARCHITECTURE -match 'AMD64|IA64') {
            $arch = 'x64'
        }
    }

    return "$os-$arch"
}

function Get-NuVersion {
    param([Parameter(Mandatory)][string]$Executable)

    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        return $null
    }

    $versionOutput = & $Executable --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $versionText = ($versionOutput -join ' ').Trim()
    if ($versionText -match '^(?:nu\s+)?(?<Version>\d+\.\d+\.\d+)') {
        return $Matches.Version
    }

    return $null
}

# --- Resolve directories ------------------------------------------------------
$breweryDir   = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$packageRoot  = (Resolve-Path -LiteralPath (Join-Path $breweryDir '..\..')).Path
$repoRoot     = (Resolve-Path -LiteralPath (Join-Path $packageRoot '..\..')).Path
$pinPath      = Join-Path $breweryDir 'pin.json'
$destDir      = if ($TargetDir) { [System.IO.Path]::GetFullPath($TargetDir) } else { Join-Path $packageRoot 'deps\nushell' }

# --- 1. Query GitHub Release Inventory ----------------------------------------
$apiUrl = if ($Version) {
    "https://api.github.com/repos/nushell/nushell/releases/tags/$Version"
} else {
    "https://api.github.com/repos/nushell/nushell/releases/latest"
}

Write-Host "Querying GitHub release inventory from $apiUrl..."
$headers = @{ "User-Agent" = "science-facility-brewery" }
if ($env:GITHUB_TOKEN) {
    $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN"
} elseif ($env:GH_TOKEN) {
    $headers["Authorization"] = "Bearer $env:GH_TOKEN"
}

$release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing
$releaseTag = [string]$release.tag_name
Write-Host "Identified release version: $releaseTag"

$platformKey = Get-HostPlatformKey
Write-Host "Detected host platform: $platformKey"

# Map asset names across standard platforms
$assetMap = [ordered]@{
    "windows-x64"   = "nu-$releaseTag-x86_64-pc-windows-msvc.zip"
    "windows-arm64" = "nu-$releaseTag-aarch64-pc-windows-msvc.zip"
    "linux-x64"     = "nu-$releaseTag-x86_64-unknown-linux-gnu.tar.gz"
    "linux-arm64"   = "nu-$releaseTag-aarch64-unknown-linux-gnu.tar.gz"
    "darwin-x64"    = "nu-$releaseTag-x86_64-apple-darwin.tar.gz"
    "darwin-arm64"  = "nu-$releaseTag-aarch64-apple-darwin.tar.gz"
}

$currentAssetName = $assetMap[$platformKey]
if (-not $currentAssetName) {
    throw "No mapped release asset for platform '$platformKey'."
}

$currentAssetObj = $release.assets | Where-Object { $_.name -eq $currentAssetName } | Select-Object -First 1
if (-not $currentAssetObj) {
    throw "Could not find asset '$currentAssetName' in release $releaseTag."
}

$downloadUrl = [string]$currentAssetObj.browser_download_url
Write-Host "Selected asset: $currentAssetName"
Write-Host "Download URL:   $downloadUrl"

# Fetch SHA256SUMS
$shaAsset = $release.assets | Where-Object { $_.name -eq "SHA256SUMS" } | Select-Object -First 1
$shaSums = @{}
if ($shaAsset) {
    Write-Host "Fetching SHA256SUMS..."
    $rawSums = (Invoke-WebRequest -Uri $shaAsset.browser_download_url -Headers $headers -UseBasicParsing).Content
    $sumsText = if ($rawSums -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($rawSums) } else { [string]$rawSums }
    foreach ($line in ($sumsText -split "`r?`n")) {
        if ($line -match '^(?<Hash>[0-9a-fA-F]{64})\s+(?<File>\S+)$') {
            $shaSums[$Matches.File] = $Matches.Hash.ToLowerInvariant()
        }
    }
}

if ($DryRun) {
    Write-Host "Dry-run complete. Would update pin.json to version $releaseTag and install $currentAssetName."
    return
}

# --- 2. Download and Verify Archive -------------------------------------------
$scratchBase = Join-Path $repoRoot 'artifacts\nushell-mcp\build'
if (-not (Test-Path -LiteralPath $scratchBase)) {
    New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null
}

$temporaryRoot = Join-Path $scratchBase ("nushell-upgrade-" + [System.Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $temporaryRoot $currentAssetName
$extractRoot = Join-Path $temporaryRoot 'extract'
$stagedRoot  = Join-Path $temporaryRoot 'staged'

New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
New-Item -ItemType Directory -Path $stagedRoot  -Force | Out-Null

try {
    Write-Host "Downloading $currentAssetName..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing

    $actualArchiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedArchiveHash = $shaSums[$currentAssetName]
    if ($expectedArchiveHash -and ($actualArchiveHash -ne $expectedArchiveHash)) {
        throw "Archive SHA-256 mismatch: expected $expectedArchiveHash, got $actualArchiveHash"
    }
    Write-Host "Archive SHA-256 verified: $actualArchiveHash"

    Write-Host "Extracting archive..."
    if ($currentAssetName -match '\.zip$') {
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
    } else {
        $tar = Get-Command 'tar' -ErrorAction Stop
        & $tar -xzf $archivePath -C $extractRoot
    }

    $executableName = if ($platformKey -match '^windows') { 'nu.exe' } else { 'nu' }
    $nuCandidates = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter $executableName)
    if ($nuCandidates.Count -eq 0) {
        throw "Could not find $executableName inside extracted archive."
    }

    $sourceDir = $nuCandidates[0].Directory.FullName
    Copy-Item -Path (Join-Path $sourceDir '*') -Destination $stagedRoot -Recurse -Force

    if ($platformKey -match '^windows') {
        Get-ChildItem -LiteralPath $stagedRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    } else {
        Get-ChildItem -LiteralPath $stagedRoot -Recurse -File | ForEach-Object {
            if ($_.Name -match '^nu$|^nu_plugin_') { chmod +x $_.FullName }
        }
    }

    $stagedExecutable = Join-Path $stagedRoot $executableName
    $stagedVersion = Get-NuVersion -Executable $stagedExecutable
    if ($stagedVersion -ne $releaseTag) {
        throw "Restored executable version ($stagedVersion) does not match release tag ($releaseTag)"
    }
    $stagedExeHash = (Get-FileHash -LiteralPath $stagedExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Verified executable: $executableName version $stagedVersion ($stagedExeHash)"

    # --- 3. Programmatically Update pin.json ----------------------------------
    if (-not $NoPinUpdate -and ($shaSums.Count -gt 0)) {
        Write-Host "Updating $pinPath for version $releaseTag..."

        $artifactsObj = [ordered]@{}
        foreach ($pKey in $assetMap.Keys) {
            $fName = $assetMap[$pKey]
            $archType = if ($fName -match '\.zip$') { 'zip' } else { 'tar.gz' }
            $eName = if ($pKey -match '^windows') { 'nu.exe' } else { 'nu' }
            $entry = [ordered]@{
                url        = "https://github.com/nushell/nushell/releases/download/$releaseTag/$fName"
                sha256     = ($shaSums[$fName] | default "")
                archive    = $archType
                executable = $eName
            }
            if ($pKey -eq $platformKey) {
                $entry["executable_sha256"] = $stagedExeHash
            }
            $artifactsObj[$pKey] = $entry
        }

        $newPin = [ordered]@{
            schema_version = 1
            tool           = "nushell"
            version        = $releaseTag
            release_url    = "https://github.com/nushell/nushell/releases/tag/$releaseTag"
            artifacts      = $artifactsObj
        }

        $newPin | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pinPath -Encoding utf8
        Write-Host "Updated pin.json successfully."
    }

    # --- 4. Deploy All Executables & Plugins into Target Directory -------------
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $stagedFiles = @(Get-ChildItem -LiteralPath $stagedRoot -Recurse -File)
    foreach ($file in $stagedFiles) {
        $filePath = $file.FullName
        $rel = $filePath.Substring($stagedRoot.Length).TrimStart('\', '/')
        $target = Join-Path $destDir $rel
        $targetParent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetParent)) {
            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        }

        try {
            Copy-Item -LiteralPath $filePath -Destination $target -Force
        } catch {
            $old = "$target.old"
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $target -Destination $old -Force
            Copy-Item -LiteralPath $filePath -Destination $target -Force
        }
    }

    # Write receipt
    $receiptPath = Join-Path $destDir 'restore-receipt.json'
    [ordered]@{
        schema_version    = 1
        tool              = "nushell"
        version           = $releaseTag
        platform          = $platformKey
        artifact_url      = $downloadUrl
        artifact_sha256   = $actualArchiveHash
        executable_name   = $executableName
        executable_sha256 = $stagedExeHash
        restored_at       = (Get-Date -Format 'o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding utf8

    Write-Host "Nushell $releaseTag successfully installed into $destDir"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- 5. Smoke Test ------------------------------------------------------------
if (-not $SkipTests) {
    Write-Host "Running smoke test battery..."
    $testScript = Join-Path $packageRoot 'tests\skills-corpus-v1.nu'
    $targetExecutable = Join-Path $destDir $executableName

    $smokeOutput = & $targetExecutable -n $testScript 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Smoke test failed with exit code ${LASTEXITCODE}:`n$($smokeOutput -join "`n")"
    }
    Write-Host "Smoke tests passed."
}

[pscustomobject]@{
    Platform   = $platformKey
    Version    = $releaseTag
    Executable = (Join-Path $destDir $executableName)
    Receipt    = (Join-Path $destDir 'restore-receipt.json')
    Status     = "ready"
}
