<#
.SYNOPSIS
    Materializes the pinned Node dependency graph into deps/node_modules and links it
    at the package root.

.DESCRIPTION
    The four steps of the node recipe. Steps 1-3 are ordinary npm hygiene; step 4 is the
    one a fresh clone cannot derive from tracked files, and the one whose absence looks
    like a missing package rather than a missing link.

      1. Stage copies of package.json and package-lock.json into the install prefix.
         npm ci requires both beside its target. The copies are ignored; edit only the
         canonical pair in brewery/node/.
      2. npm ci into the prefix, with npm's download cache pointed at build/node/npm-cache
         so routine restoration never touches the user profile or rewrites the canonical lock.
      3. Verify the staged lock did not drift from the canonical lock, and fail if it did.
      4. Junction the package root's node_modules at deps/node_modules, because Node
         resolves bare specifiers by walking up from the importing file and never looks
         inside deps/.

.PARAMETER Force
    Re-create the junction even if one is already present.
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$recipe      = $PSScriptRoot
$packageRoot = (Resolve-Path (Join-Path $recipe '..' '..')).Path
$deps        = Join-Path $packageRoot 'deps'
$cache       = Join-Path $packageRoot 'build/node/npm-cache'
$payload     = Join-Path $deps 'node_modules'
$junction    = Join-Path $packageRoot 'node_modules'

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
Push-Location $deps
try {
    npm ci --cache $cache --no-audit --no-fund
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

# --- 4. junction ----------------------------------------------------------------
if (Test-Path -LiteralPath $junction) {
    $item = Get-Item -LiteralPath $junction -Force
    $isLink = $item.LinkType -in @('Junction', 'SymbolicLink')
    if (-not $isLink) {
        throw @"
$junction exists as a real directory, not a junction.
Something (usually a stray 'npm install' run at the package root) replaced the link with a
second dependency graph. Delete it and re-run this script; the payload in deps/node_modules
is the only graph this package has.
"@
    }
    if ($Force) {
        Remove-Item -LiteralPath $junction -Force
        Write-Host "removed existing junction (-Force)"
    }
}

if (-not (Test-Path -LiteralPath $junction)) {
    New-Item -ItemType Junction -Path $junction -Target $payload | Out-Null
    Write-Host "junction $junction -> $payload"
}
else { Write-Host "junction already present (pass -Force to re-create)" }

# --- report ---------------------------------------------------------------------
Push-Location $packageRoot
try {
    $tsc = npx tsc --version 2>&1
    Write-Host "restore complete: $tsc"
}
finally { Pop-Location }
