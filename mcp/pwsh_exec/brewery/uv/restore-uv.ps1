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
$depsRoot = Join-Path $projectRoot 'deps'
$uvBinRoot = Join-Path $depsRoot 'bin\uv'
$uvExecutable = Join-Path $uvBinRoot 'uv.exe'
$receiptPath = Join-Path $uvBinRoot 'restore-receipt.json'

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

$existingVersion = Get-UvVersion -Executable $uvExecutable
$existingExecutableHash = if (Test-Path -LiteralPath $uvExecutable -PathType Leaf) {
    (Get-FileHash -LiteralPath $uvExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
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

        $expectedUvBinRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'deps\bin\uv'))
        if ([IO.Path]::GetFullPath($uvBinRoot) -ne $expectedUvBinRoot) {
            throw "Refusing to replace unexpected uv bin path: $uvBinRoot"
        }

        if (Test-Path -LiteralPath $uvBinRoot) {
            Remove-Item -LiteralPath $uvBinRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $uvBinRoot -Force | Out-Null
        Copy-Item -Path (Join-Path $stagedRoot '*') -Destination $uvBinRoot -Recurse -Force

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

$activeUvVersion = Get-UvVersion -Executable $uvExecutable
if ($activeUvVersion -ne $expectedVersion) {
    throw "Restored uv version mismatch: expected $expectedVersion, got $activeUvVersion"
}

$cacheRoot = Join-Path $projectRoot '.cache\uv'
$pythonRoot = Join-Path $depsRoot 'python'
$serverPath = Join-Path $projectRoot 'server.py'
New-Item -ItemType Directory -Path $cacheRoot, $pythonRoot -Force | Out-Null

$previousUvCacheDir = $env:UV_CACHE_DIR
$previousUvPythonInstallDir = $env:UV_PYTHON_INSTALL_DIR
$previousUvProjectEnvironment = $env:UV_PROJECT_ENVIRONMENT
$previousVirtualEnv = $env:VIRTUAL_ENV
$env:UV_CACHE_DIR = $cacheRoot
$env:UV_PYTHON_INSTALL_DIR = $pythonRoot
Remove-Item Env:UV_PROJECT_ENVIRONMENT -ErrorAction SilentlyContinue
Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue

Push-Location -LiteralPath $projectRoot
try {
    Invoke-Checked -Executable $uvExecutable -Arguments @(
        'python', 'install', $pythonVersion, '--managed-python', '--no-bin', '--no-registry'
    )

    $pythonCandidates = @(
        Get-ChildItem -LiteralPath $pythonRoot -Recurse -File -Filter 'python.exe' |
            Where-Object { $_.Directory.Name -like 'cpython-*' }
    )
    if ($pythonCandidates.Count -lt 1) {
        throw "Owned Python interpreter was not installed under $pythonRoot"
    }
    $pythonExecutable = $pythonCandidates[0].FullName
    $expectedPythonRoot = [IO.Path]::GetFullPath($pythonRoot)
    if (-not ([IO.Path]::GetFullPath($pythonExecutable).StartsWith(
        ($expectedPythonRoot.TrimEnd('\') + '\'),
        [StringComparison]::OrdinalIgnoreCase
    ))) {
        throw "Refusing to use Python outside $pythonRoot`: $pythonExecutable"
    }

    $requirementsPath = Join-Path $cacheRoot 'requirements.runtime.txt'
    Invoke-Checked -Executable $uvExecutable -Arguments @(
        'export',
        '--quiet',
        '--project', $projectRoot,
        '--frozen',
        '--no-dev',
        '--no-emit-project',
        '-o', $requirementsPath
    )
    Invoke-Checked -Executable $uvExecutable -Arguments @(
        'pip', 'install',
        '--python', $pythonExecutable,
        '--break-system-packages',
        '--exact',
        '--strict',
        '--link-mode', 'copy',
        '-r', $requirementsPath
    )

    $registrationRoot = Join-Path $depsRoot 'registrations'
    $registrationPath = Join-Path $registrationRoot 'pwsh_exec.json'
    New-Item -ItemType Directory -Path $registrationRoot -Force | Out-Null
    [ordered]@{
        mcpServers = [ordered]@{
            pwsh_exec = [ordered]@{
                command = $pythonExecutable.Replace('\', '/')
                args = @(
                    '-B'
                    $serverPath.Replace('\', '/')
                )
                env = [ordered]@{
                    MCP_POWERSHELL_EXECUTABLE = (Join-Path $depsRoot 'bin\pwsh\pwsh.exe').Replace('\', '/')
                    MCP_POWERSHELL_PROFILE = (Join-Path $projectRoot 'scripts\pwsh\profile-pwsh.ps1').Replace('\', '/')
                }
            }
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $registrationPath -Encoding utf8

    if (-not $SkipTests) {
        Invoke-Checked -Executable $pythonExecutable -Arguments @(
            '-B', '-W', 'error',
            '-m', 'unittest', 'discover', '-s', 'tests', '-v'
        )
    }
}
finally {
    Pop-Location
    if ($null -eq $previousUvCacheDir) { Remove-Item Env:UV_CACHE_DIR -ErrorAction SilentlyContinue } else { $env:UV_CACHE_DIR = $previousUvCacheDir }
    if ($null -eq $previousUvPythonInstallDir) { Remove-Item Env:UV_PYTHON_INSTALL_DIR -ErrorAction SilentlyContinue } else { $env:UV_PYTHON_INSTALL_DIR = $previousUvPythonInstallDir }
    if ($null -eq $previousUvProjectEnvironment) { Remove-Item Env:UV_PROJECT_ENVIRONMENT -ErrorAction SilentlyContinue } else { $env:UV_PROJECT_ENVIRONMENT = $previousUvProjectEnvironment }
    if ($null -eq $previousVirtualEnv) { Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue } else { $env:VIRTUAL_ENV = $previousVirtualEnv }
}

[pscustomobject]@{
    ProjectRoot = $projectRoot
    UvExecutable = $uvExecutable
    PythonExecutable = $pythonExecutable
    Registration = (Join-Path $projectRoot 'deps\registrations\pwsh_exec.json')
    UvVersion = $expectedVersion
    PythonVersion = $pythonVersion
}
