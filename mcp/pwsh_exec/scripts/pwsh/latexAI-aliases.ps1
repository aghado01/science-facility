# D:\aghado01\science-facility\mcp\pwsh_exec\scripts\pwsh\latexAI-aliases.ps1

# Wrapper functions — Set-Alias only accepts a single command name, so switches
# (-I lib -I blib/lib) and LaTeXAI fork paths live here.
# Perl is resolved from the dedicated PERL_ROOT variable (User scope; PERL_HOME
# is its perl\ subdirectory). No filesystem layout is assumed beneath the
# portable root, and ambient PATH is bypassed so this never hits stock or
# MSYS2 perl. A missing PERL_ROOT fails loudly at load time rather than at
# first use.

$script:PerlRoot = $env:PERL_ROOT
if (-not $script:PerlRoot -and $env:PERL_HOME) {
    $script:PerlRoot = Split-Path -Parent $env:PERL_HOME
}
if (-not $script:PerlRoot) {
    Write-Warning "latexAI-aliases: PERL_ROOT (or PERL_HOME) is not set; lxml/ltst/lmath will not work in this session."
}

$script:StrawberryPerl = Join-Path $script:PerlRoot "perl\bin\perl.exe"
$script:ProveExe = Join-Path $script:PerlRoot "perl\bin\prove.bat"
# The fork root is declared by the project (LaTeXAI/.mcp.json sets LATEXAI_ROOT
# on the pwsh_exec server); the literal below is only the fallback for shells
# opened outside that project.
$script:LaTeXAIRoot = if ($env:LATEXAI_ROOT) { $env:LATEXAI_ROOT } else { "D:\aipithicus\LaTeXAI" }
$script:LaTeXAILib = "$script:LaTeXAIRoot\lib"
$script:LaTeXAIBlib = "$script:LaTeXAIRoot\blib\lib"
$script:LaTeXAIBin = "$script:LaTeXAIRoot\bin"

# Core engine CLIs routed to local LaTeXAI fork
function Invoke-LaTeXML { & $script:StrawberryPerl -I $script:LaTeXAILib -I $script:LaTeXAIBlib "$script:LaTeXAIBin\latexml" @args }
function Invoke-LaTeXMLPost { & $script:StrawberryPerl -I $script:LaTeXAILib -I $script:LaTeXAIBlib "$script:LaTeXAIBin\latexmlpost" @args }
function Invoke-LaTeXMLC { & $script:StrawberryPerl -I $script:LaTeXAILib -I $script:LaTeXAIBlib "$script:LaTeXAIBin\latexmlc" @args }

# Test runner (Strawberry's prove harness with LaTeXAI searchpaths)
function Invoke-LaTeXMLTest { & $script:ProveExe -I $script:LaTeXAILib -I $script:LaTeXAIBlib @args }

# Quick math test helper for rapid prototyping
function Test-LaTeXMLMath {
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Expression,
        [string]$Preload,
        [switch]$Capture
    )
    $cmdArgs = @()
    if ($Preload) { $cmdArgs += "--preload=$Preload" }
    if ($Capture) { $cmdArgs += "--capture" }
    $cmdArgs += "literal:$Expression"
    Invoke-LaTeXML @cmdArgs
}

function Get-LaTeXMLAliases {
    $aliases = @{
        'lxml'  = 'Invoke-LaTeXML'      # latexml -I lib -I blib/lib [args]
        'lxmlp' = 'Invoke-LaTeXMLPost'  # latexmlpost
        'lxmlc' = 'Invoke-LaTeXMLC'     # latexmlc
        'ltst'  = 'Invoke-LaTeXMLTest'  # prove -I lib -I blib/lib [args]
        'lmath' = 'Test-LaTeXMLMath'    # test a math literal directly
    }
    return $aliases
}

$(Get-LaTeXMLAliases).GetEnumerator() | ForEach-Object {
    New-Alias -Name $_.Key -Value $_.Value -Scope Global -Force
}
