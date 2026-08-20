if (-not $clilibBin) {
    $clilibBin = "$env:PORTABLE_ROOT/.cli-lib/bin"
}

$script:cliCompletionsPath = "$clilibBin/complete"
$script:cliCompletions = @('rg.ps1', 'fd.ps1')
foreach ($completion in $cliCompletions) {
    if (-not (Test-Path "$cliCompletionsPath/$completion")) {
        Write-Warning "CLI completion script $completion not found at $cliCompletionsPath"
    }
    else {
        . "$cliCompletionsPath/$completion"
    }
}
