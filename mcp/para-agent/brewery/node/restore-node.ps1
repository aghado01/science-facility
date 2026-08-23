<#
.SYNOPSIS
    Materializes the pinned Node dependency graph into deps/node_modules.

.DESCRIPTION
    The three steps of the node recipe:

      1. Stage copies of package.json and package-lock.json into the install prefix.
         npm ci requires both beside its target. The copies are ignored; edit only the
         canonical pair in brewery/node/.
      2. npm ci into the prefix, with npm's download cache pointed at build/node/npm-cache
         so routine restoration never touches the user profile or rewrites the canonical lock.
      3. Verify the staged lock did not drift from the canonical lock, and fail if it did.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$recipe      = $PSScriptRoot
$packageRoot = (Resolve-Path (Join-Path $recipe '..' '..')).Path
$deps        = Join-Path $packageRoot 'deps'
$cache       = Join-Path $packageRoot 'build/node/npm-cache'
$payload     = Join-Path $deps 'node_modules'

$canonicalManifest = Join-Path $recipe 'package.json'
$canonicalLock     = Join-Path $recipe 'package-lock.json'

foreach ($f in @($canonicalManifest, $canonicalLock)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing pin: $f" }
}

# --- 1. stage -------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $deps, $cache | Out-Null
Copy-Item -LiteralPath $canonicalManifest -Destination (Join-Path $deps 'package.json') -Force
Copy-Item -LiteralPath $canonicalLock     -Destination (Join-Path $deps 'package-lock.json') -Force
Write-Host "staged pins -> $deps"

# --- 2. install -----------------------------------------------------------------
$npm = if (Get-Command npm.cmd -ErrorAction SilentlyContinue) { 'npm.cmd' } else { 'npm' }
Push-Location $deps
try {
    $null | & $npm ci --cache $cache --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE" }
}
finally { Pop-Location }

if (-not (Test-Path -LiteralPath $payload)) { throw "npm ci reported success but $payload is absent" }

# --- 3. verify the lock did not drift -------------------------------------------
$stagedLockHash    = (Get-FileHash -LiteralPath (Join-Path $deps 'package-lock.json') -Algorithm SHA256).Hash
$canonicalLockHash = (Get-FileHash -LiteralPath $canonicalLock -Algorithm SHA256).Hash
if ($stagedLockHash -ne $canonicalLockHash) {
    throw @"
Lock drift: npm rewrote the staged lock during install.
  canonical $canonicalLock
  staged    $(Join-Path $deps 'package-lock.json')
The canonical lock is the pin. To move versions deliberately, edit brewery/node/package.json,
regenerate with 'npm install --package-lock-only' in that directory, review the diff, then re-run this script.
"@
}
Write-Host "lock verified against canonical pin"

# --- report ---------------------------------------------------------------------
Write-Host "restore complete (node_modules restored in $payload)"
