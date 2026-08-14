[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UvVersion {
    param([Parameter(Mandatory)][string]$Executable)

    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        return $null
    }

    $versionOutput = & $Executable --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $versionText = ($versionOutput -join ' ').Trim()
    if ($versionText -notmatch '^uv\s+(?<Version>\d+\.\d+\.\d+)') {
        throw "Unexpected uv version output from ${Executable}: $versionText"
    }

    return $Matches.Version
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Executable $($Arguments -join ' ')"
    }
}

$breweryRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $breweryRoot '..\..')).Path
$pinPath = Join-Path $breweryRoot 'pin.json'
$pythonPinPath = Join-Path $projectRoot '.python-version'
$packagesRoot = Join-Path $projectRoot 'packages'
$bootstrapRoot = Join-Path $packagesRoot 'uv'
$bootstrapExecutable = Join-Path $bootstrapRoot 'uv.exe'
$receiptPath = Join-Path $bootstrapRoot 'restore-receipt.json'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This pwsh_exec distribution currently bundles Windows PowerShell and supports Windows restoration only.'
}

$architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$platformKey = "windows-$architecture"
$pin = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
$artifactProperty = $pin.artifacts.PSObject.Properties[$platformKey]
if ($null -eq $artifactProperty) {
    throw "No uv artifact is pinned for platform '$platformKey'."
}

$artifact = $artifactProperty.Value
$expectedVersion = [string]$pin.version
$expectedHash = ([string]$artifact.sha256).ToLowerInvariant()
$expectedExecutableHash = ([string]$artifact.executable_sha256).ToLowerInvariant()
$pythonVersion = (Get-Content -LiteralPath $pythonPinPath -Raw).Trim()

if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
    throw "Invalid SHA-256 in ${pinPath}: $expectedHash"
}
if ($expectedExecutableHash -notmatch '^[0-9a-f]{64}$') {
    throw "Invalid executable SHA-256 in ${pinPath}: $expectedExecutableHash"
}
if ($pythonVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "Invalid Python version in ${pythonPinPath}: $pythonVersion"
}

$existingVersion = Get-UvVersion -Executable $bootstrapExecutable
$existingExecutableHash = if (Test-Path -LiteralPath $bootstrapExecutable -PathType Leaf) {
    (Get-FileHash -LiteralPath $bootstrapExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
}
$restoreBootstrap = (
    $Force -or
    ($existingVersion -ne $expectedVersion) -or
    ($existingExecutableHash -ne $expectedExecutableHash)
)

if ($restoreBootstrap) {
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("pwsh_exec-uv-" + [Guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $temporaryRoot 'uv.zip'
    $extractRoot = Join-Path $temporaryRoot 'extract'
    $stagedRoot = Join-Path $temporaryRoot 'staged'

    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $stagedRoot -Force | Out-Null

    try {
        Write-Host "Downloading uv $expectedVersion for $platformKey"
        Invoke-WebRequest -Uri ([string]$artifact.url) -OutFile $archivePath -UseBasicParsing

        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "uv archive SHA-256 mismatch: expected $expectedHash, got $actualHash"
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
        $uvCandidates = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter ([string]$artifact.executable))
        if ($uvCandidates.Count -ne 1) {
            throw "Expected one $($artifact.executable) in the uv archive; found $($uvCandidates.Count)."
        }

        $artifactRoot = $uvCandidates[0].Directory.FullName
        Copy-Item -Path (Join-Path $artifactRoot '*') -Destination $stagedRoot -Recurse -Force
        Get-ChildItem -LiteralPath $stagedRoot -Recurse -File | Unblock-File

        $stagedExecutable = Join-Path $stagedRoot 'uv.exe'
        $stagedVersion = Get-UvVersion -Executable $stagedExecutable
        if ($stagedVersion -ne $expectedVersion) {
            throw "Restored uv version mismatch: expected $expectedVersion, got $stagedVersion"
        }
        $stagedExecutableHash = (Get-FileHash -LiteralPath $stagedExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($stagedExecutableHash -ne $expectedExecutableHash) {
            throw "Restored uv executable SHA-256 mismatch: expected $expectedExecutableHash, got $stagedExecutableHash"
        }

        $expectedBootstrapRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'packages\uv'))
        if ([IO.Path]::GetFullPath($bootstrapRoot) -ne $expectedBootstrapRoot) {
            throw "Refusing to replace unexpected bootstrap path: $bootstrapRoot"
        }

        if (Test-Path -LiteralPath $bootstrapRoot) {
            Remove-Item -LiteralPath $bootstrapRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $bootstrapRoot -Force | Out-Null
        Copy-Item -Path (Join-Path $stagedRoot '*') -Destination $bootstrapRoot -Recurse -Force

        [ordered]@{
            schema_version = 1
            tool = 'uv'
            version = $expectedVersion
            platform = $platformKey
            artifact_url = [string]$artifact.url
            artifact_sha256 = $actualHash
            executable_sha256 = $stagedExecutableHash
        } | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding utf8
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }
}

$bootstrapVersion = Get-UvVersion -Executable $bootstrapExecutable
if ($bootstrapVersion -ne $expectedVersion) {
    throw "Bootstrap uv version mismatch: expected $expectedVersion, got $bootstrapVersion"
}

Push-Location -LiteralPath $projectRoot
try {
    Invoke-Checked -Executable $bootstrapExecutable -Arguments @(
        'python', 'install', $pythonVersion, '--no-bin'
    )
    Invoke-Checked -Executable $bootstrapExecutable -Arguments @(
        'sync', '--locked', '--managed-python', '--python', $pythonVersion
    )

    $runtimeUv = Join-Path $projectRoot '.venv\Scripts\uv.exe'
    $runtimeVersion = Get-UvVersion -Executable $runtimeUv
    if ($runtimeVersion -ne $expectedVersion) {
        throw "Runtime uv version mismatch: expected $expectedVersion, got $runtimeVersion"
    }

    $registrationRoot = Join-Path $packagesRoot 'registrations'
    $registrationPath = Join-Path $registrationRoot 'pwsh_exec.json'
    New-Item -ItemType Directory -Path $registrationRoot -Force | Out-Null
    [ordered]@{
        mcpServers = [ordered]@{
            pwsh_exec = [ordered]@{
                command = $runtimeUv.Replace('\', '/')
                args = @(
                    'run'
                    '--project'
                    $projectRoot.Replace('\', '/')
                    '--no-cache'
                    '--locked'
                    '--no-sync'
                    'python'
                    '-B'
                    (Join-Path $projectRoot 'server.py').Replace('\', '/')
                )
                env = [ordered]@{}
            }
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $registrationPath -Encoding utf8

    if (-not $SkipTests) {
        Invoke-Checked -Executable $runtimeUv -Arguments @(
            'run', '--no-cache', '--locked', '--no-sync',
            'python', '-B', '-W', 'error',
            '-m', 'unittest', 'discover', '-s', 'tests', '-v'
        )
    }
}
finally {
    Pop-Location
}

[pscustomobject]@{
    ProjectRoot = $projectRoot
    BootstrapUv = $bootstrapExecutable
    RuntimeUv = (Join-Path $projectRoot '.venv\Scripts\uv.exe')
    Registration = (Join-Path $projectRoot 'packages\registrations\pwsh_exec.json')
    UvVersion = $expectedVersion
    PythonVersion = $pythonVersion
}
