# Write-Host "$env:COMPUTERNAME $PSCommandPath..." -ForegroundColor Green
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Set PSModules for local standard modules like psreadline and threadjob, and shared portable modules such as plaster and pester (non overlapping sets)
$env:PSModulePath = "$PSHOME\Modules;$(Split-Path -Parent $PSScriptRoot)\Modules"

$script:historyFileName = "ConsoleHost_history"
if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
    Set-PSReadLineOption -HistorySavePath "$PSHOME\.history\$historyFileName.txt" -HistorySaveStyle SaveIncrementally
}

function Set-ConsolePrompt {
    $prefix = 'PS'
    $pathLeaf = Split-Path -Leaf $PWD
    $suffix = if ($NestedPromptLevel -ge 1) { '>> ' } else { '> ' }
    return "$prefix $pathLeaf$suffix"
}

function prompt {
    Set-ConsolePrompt
}