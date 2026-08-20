# Write-Host "$env:COMPUTERNAME $PSCommandPath..." -ForegroundColor Green
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$parentDirPath = $(Split-Path -Parent $PSScriptRoot)

# Set PSModules for local standard modules like psreadline and threadjob, and shared portable modules such as plaster and pester (non overlapping sets)
# $env:PSModulePath = "$PSHOME\Modules;$parentDirPath\Modules"

$script:historyFileName = "ConsoleHost_history"
if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
    Set-PSReadLineOption -HistorySavePath "$PSHOME\.history\$historyFileName.txt" -HistorySaveStyle SaveIncrementally
}

# pwsh_exec root 
$parentParentDir = $(Split-Path -Parent $parentDirPath)

# test-path $parentParentDir/scripts/cli-completions.ps1
# test-path "$parentParentDir/scripts/console-prompt.ps1"
. "$parentParentDir/scripts/console-prompt.ps1"
. "$parentParentDir/scripts/cli-completions.ps1"
. "$parentParentDir/scripts/dotnet-aliases.ps1"
