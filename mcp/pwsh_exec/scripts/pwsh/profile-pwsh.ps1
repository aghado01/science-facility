# Default pwsh_exec profile. MCP children are noninteractive and project-neutral.
# Interactive console furniture is opt-in via MCP_POWERSHELL_INTERACTIVE=1.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$psHomeParent = Split-Path -Parent $PSHOME
$toolsPath = Join-Path -Path $psHomeParent -ChildPath 'tools\cli'
if (Test-Path -LiteralPath $toolsPath) {
    $env:PATH = "$toolsPath;$env:PATH"
}

if ($env:MCP_POWERSHELL_INTERACTIVE -eq '1') {
    $script:historyFileName = 'ConsoleHost_history'
    if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
        Set-PSReadLineOption -HistorySavePath "$PSHOME\.history\$historyFileName.txt" -HistorySaveStyle SaveIncrementally
    }
    if (Test-Path -LiteralPath "$PSScriptRoot/console-prompt.ps1") {
        . "$PSScriptRoot/console-prompt.ps1"
    }
    if (Test-Path -LiteralPath "$PSScriptRoot/dotnet-aliases.ps1") {
        . "$PSScriptRoot/dotnet-aliases.ps1"
    }
    if (Test-Path -LiteralPath "$PSScriptRoot/cli-completions.ps1") {
        . "$PSScriptRoot/cli-completions.ps1"
    }
}
