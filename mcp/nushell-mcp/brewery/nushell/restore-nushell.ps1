<#
.SYNOPSIS
    Downloads and materializes the pinned Nushell engine distribution into deps/nushell.

.DESCRIPTION
    Detects the current host OS and architecture, matches it against brewery/nushell/pin.json,
    downloads the official Nushell release archive, verifies SHA-256 checksums, extracts
    the binary and bundled plugins, stages them into deps/nushell, and verifies the installation.

.PARAMETER Force
    Re-download and restore even if the installed version and binary hash match the pin.

.PARAMETER SkipTests
    Skip running the smoke test battery after successful restoration.

.PARAMETER PlatformOverride
    Explicitly specify the platform key (e.g. windows-x64, linux-x64, darwin-arm64).

.PARAMETER TargetDir
    Custom destination path (defaults to deps/nushell relative to package root).
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipTests,
    [string]$PlatformOverride,
    [string]$TargetDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HostPlatformKey {
    if ($PlatformOverride) {
        return $PlatformOverride.ToLowerInvariant()
    }

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

function Invoke-Extraction {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$ArchiveType
    )

    if ($ArchiveType -eq 'zip') {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force
    } elseif ($ArchiveType -eq 'tar.gz') {
        $tarCmd = Get-Command 'tar' -ErrorAction SilentlyContinue
        if (-not $tarCmd) {
            throw "The 'tar' utility is required to extract $ArchivePath on this platform."
        }
        & $tarCmd -xzf $ArchivePath -C $DestinationPath
        if ($LASTEXITCODE -ne 0) {
            throw "tar extraction failed with exit code $LASTEXITCODE"
        }
    } else {
        throw "Unsupported archive format: $ArchiveType"
    }
}

# --- Resolve directories ------------------------------------------------------
$breweryDir   = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$packageRoot  = (Resolve-Path -LiteralPath (Join-Path $breweryDir '..\..')).Path
$pinPath      = Join-Path $breweryDir 'pin.json'

if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) {
    throw "pin.json not found at $pinPath"
}

$pin = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
$expectedVersion = [string]$pin.version

$platformKey = Get-HostPlatformKey
$artifactProperty = $pin.artifacts.PSObject.Properties[$platformKey]
if ($null -eq $artifactProperty) {
    $availablePlatforms = ($pin.artifacts.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
    throw "No Nushell artifact is pinned for platform '$platformKey'. Available platforms: $availablePlatforms"
}

$artifact = $artifactProperty.Value
$expectedArchiveHash = ([string]$artifact.sha256).ToLowerInvariant()
$expectedExecutableHash = if ($artifact.executable_sha256) { ([string]$artifact.executable_sha256).ToLowerInvariant() } else { $null }

$destDir = if ($TargetDir) {
    [System.IO.Path]::GetFullPath($TargetDir)
} else {
    Join-Path $packageRoot 'deps\nushell'
}

$executableName = [string]$artifact.executable
$targetExecutable = Join-Path $destDir $executableName
$receiptPath = Join-Path $destDir 'restore-receipt.json'

# --- Check current state ------------------------------------------------------
$existingVersion = Get-NuVersion -Executable $targetExecutable
$existingHash = if (Test-Path -LiteralPath $targetExecutable -PathType Leaf) {
    (Get-FileHash -LiteralPath $targetExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
} else {
    $null
}

$needsRestore = (
    $Force -or
    ($null -eq $existingVersion) -or
    ($existingVersion -ne $expectedVersion) -or
    ($expectedExecutableHash -and ($existingHash -ne $expectedExecutableHash))
)

if ($needsRestore) {
    Write-Host "Restoring Nushell $expectedVersion for platform [$platformKey]..."
    
    # Scratch staging directory
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $packageRoot '..\..')).Path
    $scratchBase = Join-Path $repoRoot 'artifacts\nushell-mcp\build'
    if (-not (Test-Path -LiteralPath $scratchBase)) {
        New-Item -ItemType Directory -Path $scratchBase -Force | Out-Null
    }
    $temporaryRoot = Join-Path $scratchBase ("nushell-restore-" + [System.Guid]::NewGuid().ToString('N'))
    $archiveName = "nushell-$expectedVersion-$platformKey." + [string]$artifact.archive
    $archivePath = Join-Path $temporaryRoot $archiveName
    $extractRoot = Join-Path $temporaryRoot 'extract'
    $stagedRoot  = Join-Path $temporaryRoot 'staged'

    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $stagedRoot  -Force | Out-Null

    try {
        Write-Host "Downloading $($artifact.url)..."
        Invoke-WebRequest -Uri ([string]$artifact.url) -OutFile $archivePath -UseBasicParsing

        $actualArchiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualArchiveHash -ne $expectedArchiveHash) {
            throw "Archive SHA-256 mismatch for $($artifact.url): expected $expectedArchiveHash, got $actualArchiveHash"
        }
        Write-Host "Archive SHA-256 verified: $actualArchiveHash"

        Write-Host "Extracting archive..."
        Invoke-Extraction -ArchivePath $archivePath -DestinationPath $extractRoot -ArchiveType ([string]$artifact.archive)

        # Locate directory containing nu / nu.exe
        $nuCandidates = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter $executableName)
        if ($nuCandidates.Count -eq 0) {
            throw "Could not find $executableName inside extracted archive."
        }

        $sourceDir = $nuCandidates[0].Directory.FullName
        Copy-Item -Path (Join-Path $sourceDir '*') -Destination $stagedRoot -Recurse -Force

        # Unblock files on Windows
        if ($platformKey -match '^windows') {
            Get-ChildItem -LiteralPath $stagedRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
        } else {
            # Make binaries executable on Unix/macOS
            Get-ChildItem -LiteralPath $stagedRoot -Recurse -File | ForEach-Object {
                if ($_.Name -match '^nu$|^nu_plugin_') {
                    chmod +x $_.FullName
                }
            }
        }

        $stagedExecutable = Join-Path $stagedRoot $executableName
        $stagedVersion = Get-NuVersion -Executable $stagedExecutable
        if ($stagedVersion -ne $expectedVersion) {
            throw "Restored binary version mismatch: expected $expectedVersion, got $stagedVersion"
        }

        $stagedHash = (Get-FileHash -LiteralPath $stagedExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expectedExecutableHash -and ($stagedHash -ne $expectedExecutableHash)) {
            throw "Restored executable SHA-256 mismatch: expected $expectedExecutableHash, got $stagedHash"
        }

        # Stage to destination directory
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        # Deploy files into destDir, handling locked in-use executables
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
                # If target is locked, rename to .old and copy fresh
                $old = "$target.old"
                if (Test-Path -LiteralPath $old) {
                    Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
                }
                Move-Item -LiteralPath $target -Destination $old -Force
                Copy-Item -LiteralPath $filePath -Destination $target -Force
            }
        }

        # Write receipt
        [ordered]@{
            schema_version     = 1
            tool               = "nushell"
            version            = $expectedVersion
            platform           = $platformKey
            artifact_url       = [string]$artifact.url
            artifact_sha256    = $actualArchiveHash
            executable_name    = $executableName
            executable_sha256  = $stagedHash
            restored_at        = (Get-Date -Format 'o')
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding utf8

        Write-Host "Nushell $expectedVersion successfully restored to $destDir"
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-Host "Nushell $existingVersion is already restored and matches pin ($platformKey)."
}

# --- Post-restore verification & smoke test -----------------------------------
$activeVersion = Get-NuVersion -Executable $targetExecutable
if ($activeVersion -ne $expectedVersion) {
    throw "Active Nushell executable version ($activeVersion) does not match expected ($expectedVersion)"
}

if (-not $SkipTests) {
    Write-Host "Running smoke test battery..."
    $configPath = Join-Path $packageRoot 'config.nu'
    $testScript = Join-Path $packageRoot 'tests\skills-corpus-v1.nu'

    $smokeOutput = & $targetExecutable -n $testScript 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Smoke test suite failed with exit code ${LASTEXITCODE}:`n$($smokeOutput -join "`n")"
    }
    Write-Host "Smoke tests passed."
}

[pscustomobject]@{
    Platform     = $platformKey
    Version      = $expectedVersion
    Executable   = $targetExecutable
    Receipt      = $receiptPath
    Status       = "ready"
}
