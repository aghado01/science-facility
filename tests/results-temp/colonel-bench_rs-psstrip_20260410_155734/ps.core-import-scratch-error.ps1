
$script:ProjectRoot = $PSScriptRoot | Split-Path
$script:MonoRepoRoot = $script:ProjectRoot | Split-Path

Import-Module "$PSScriptRoot/spc.core.hpc.psm1" -Force -ErrorAction Stop
Import-Module "$PSScriptRoot/spc.core.state.psm1" -Force -ErrorAction Stop
Import-Module "../ps.core." -Force -ErrorAction Stop


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


if (-not ([System.Management.Automation.PSTypeName]'SpcCore.PottsModel').Type)
{
    $csPath = Join-Path $script:ProjectRoot 'scripts\spc.physics.cs'
    if (-not (Test-Path $csPath))
    {
        throw "C# kernel not found at $csPath. Expected layout: ps.core.pwshspc/scripts/spc.physics.cs"
    }
    $csharpSource = Get-Content -Path $csPath -Raw
    Add-Type -TypeDefinition $csharpSource -Language CSharp
