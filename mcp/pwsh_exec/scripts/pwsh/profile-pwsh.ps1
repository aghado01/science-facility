# Write-Host "$env:COMPUTERNAME $PSCommandPath..." -ForegroundColor Green
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$parentDirPath = $(Split-Path -Parent $PSScriptRoot)

# Set PSModules for local standard modules like psreadline and threadjob, and shared portable modules such as plaster and pester (non overlapping sets)
# $env:PSModulePath = "$PSHOME\Modules;$parentDirPath\Modules"

$script:historyFileName = "ConsoleHost_history"
if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
    Set-PSReadLineOption -HistorySavePath "$PSHOME\.history\$historyFileName.txt" -HistorySaveStyle SaveIncrementally
}

if (Test-Path -LiteralPath "$PSScriptRoot/console-prompt.ps1") {
    . "$PSScriptRoot/console-prompt.ps1"
}
if (Test-Path -LiteralPath "$PSScriptRoot/cli-completions.ps1") {
    . "$PSScriptRoot/cli-completions.ps1"
}
if (Test-Path -LiteralPath "$PSScriptRoot/dotnet-aliases.ps1") {
    . "$PSScriptRoot/dotnet-aliases.ps1"
}
