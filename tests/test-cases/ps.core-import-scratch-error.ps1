
# --- Path anchors (computed once, used everywhere) ---
# $PSScriptRoot = .../ps.core.pwshspc/src
# ProjectRoot   = .../ps.core.pwshspc           (one level up)
# MonoRepoRoot  = .../PowerShellCore             (two levels up — peer projects live here)
$script:ProjectRoot = $PSScriptRoot | Split-Path
$script:MonoRepoRoot = $script:ProjectRoot | Split-Path

# Core SPC modules (always colocated in src/)
Import-Module "$PSScriptRoot/spc.core.hpc.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot/spc.core.state.psm1" -Force -ErrorAction Stop
Import-Module "../ps.core." -Force -ErrorAction Stop


# Canonical math/metrics (Hamming, SimHash) — sibling project under MonoRepoRoot
# Layout: PowerShellCore/ps.core.mathdig/src/ps.core.math.measures.psm1
$_mathdigSrc = Join-Path $script:MonoRepoRoot 'ps.core.mathdig\src'
$_mathMeasuresPath = Join-Path $_mathdigSrc 'ps.core.math.measures.psm1'
$_mathLshPath = Join-Path $_mathdigSrc 'ps.core.math.lsh.psm1'

if (Test-Path $_mathMeasuresPath)
{
    Import-Module $_mathMeasuresPath -Force -ErrorAction SilentlyContinue
}
else
{
    Write-Verbose "ps.core.mathdig not found at $_mathMeasuresPath; Get-HammingDistance must be available via module path."
}
if (Test-Path $_mathLshPath)
{
    Import-Module $_mathLshPath -Force -ErrorAction SilentlyContinue
}

# =============================================================================
# 1. C# KERNEL EMBEDDING
# =============================================================================
# UPDATES: Added SetSpins() to allow resuming simulation state.

# should I have separate files for potts and union-find?
if (-not ([System.Management.Automation.PSTypeName]'SpcCore.PottsModel').Type)
{
    # C# kernel: scripts/spc.physics.cs at project root
    $csPath = Join-Path $script:ProjectRoot 'scripts\spc.physics.cs'
    if (-not (Test-Path $csPath))
    {
        throw "C# kernel not found at $csPath. Expected layout: ps.core.pwshspc/scripts/spc.physics.cs"
    }
    $csharpSource = Get-Content -Path $csPath -Raw
    Add-Type -TypeDefinition $csharpSource -Language CSharp
