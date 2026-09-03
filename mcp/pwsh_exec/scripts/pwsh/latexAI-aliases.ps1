# D:\aghado01\science-facility\mcp\pwsh_exec\scripts\pwsh\latexml-aliases.ps1

# Wrapper functions — Set-Alias only accepts a single command name, so switches
# (-I lib -I blib/lib) and LaTeXAI fork paths live here.
# Resolved from portable root and local fork — ambient PATH is bypassed so
# this works deterministically and never hits stock or MSYS2 perl.

$script:StrawberryPerl = "$env:PORTABLE_ROOT\strawberry-perl\perl\bin\perl.exe"
$script:ProveExe = "$env:PORTABLE_ROOT\strawberry-perl\perl\bin\prove.bat"
$script:LaTeXAIRoot = "D:\aipithicus\LaTeXAI"
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
