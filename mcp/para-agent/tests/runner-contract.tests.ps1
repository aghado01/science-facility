$ErrorActionPreference = 'Stop'
$testRoot = $PSScriptRoot
$runner = Join-Path $testRoot 'run.ps1'
$fixtureRoot = Join-Path $testRoot 'fixtures/runner'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) {
    $pwsh = Join-Path $PSHOME 'pwsh'
}

$counts = [ordered]@{
    schema_version = 1
    discovered = 0
    completed = 0
    passed = 0
    failed = 0
    skipped = 0
    cancelled = 0
}

function Test-RunnerCase {
    param(
        [string] $Name,
        [string] $Fixture,
        [int] $ExpectedExit,
        [bool] $ExpectAbort,
        [switch] $Live,
        [string] $Suite
    )

    $counts.discovered += 1
    $manifest = Join-Path (Join-Path $fixtureRoot $Fixture) 'manifest.json'
    $runnerArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $runner,
        '-ManifestPath', $manifest
    )
    if ($Live) {
        $runnerArguments += '-Live'
    }
    if (-not [string]::IsNullOrWhiteSpace($Suite)) {
        $runnerArguments += @('-Suite', $Suite)
    }
    $caseOutput = @(& $pwsh @runnerArguments 2>&1)
    $caseExit = $LASTEXITCODE
    $text = $caseOutput -join "`n"
    $hasAbort = $text.Contains('SUITE-ABORTED', [StringComparison]::Ordinal)
    $hasFinal = $text.Contains('PARA_MANIFEST_SUMMARY ', [StringComparison]::Ordinal)
    $ok = $caseExit -eq $ExpectedExit -and $hasAbort -eq $ExpectAbort -and ($ExpectAbort -or $hasFinal)

    $counts.completed += 1
    if ($ok) {
        $counts.passed += 1
    } else {
        $counts.failed += 1
        [Console]::Error.WriteLine("runner contract '$Name' failed: exit=$caseExit abort=$hasAbort final=$hasFinal")
    }
}

Test-RunnerCase -Name 'pass' -Fixture 'pass' -ExpectedExit 0 -ExpectAbort $false
Test-RunnerCase -Name 'empty manifest' -Fixture 'zero' -ExpectedExit 1 -ExpectAbort $true
Test-RunnerCase -Name 'missing suite' -Fixture 'missing' -ExpectedExit 1 -ExpectAbort $true
Test-RunnerCase -Name 'child nonzero' -Fixture 'nonzero' -ExpectedExit 1 -ExpectAbort $true
Test-RunnerCase -Name 'missing summary' -Fixture 'no-summary' -ExpectedExit 1 -ExpectAbort $true
Test-RunnerCase -Name 'count mismatch' -Fixture 'count-mismatch' -ExpectedExit 1 -ExpectAbort $true
Test-RunnerCase -Name 'aborted child' -Fixture 'abort' -ExpectedExit 1 -ExpectAbort $true
Test-RunnerCase -Name 'live skip fails closed' -Fixture 'skip' -ExpectedExit 1 -ExpectAbort $true -Live
Test-RunnerCase -Name 'live selection accepts a live suite' -Fixture 'selection' -ExpectedExit 0 -ExpectAbort $false -Live -Suite 'live-pass'
Test-RunnerCase -Name 'live selection rejects bounded-only suite' -Fixture 'selection' -ExpectedExit 1 -ExpectAbort $true -Live -Suite 'bounded-pass'
Test-RunnerCase -Name 'missing skipped count' -Fixture 'missing-count' -ExpectedExit 1 -ExpectAbort $true
Test-RunnerCase -Name 'negative count' -Fixture 'negative-count' -ExpectedExit 1 -ExpectAbort $true
Test-RunnerCase -Name 'fractional count' -Fixture 'fractional-count' -ExpectedExit 1 -ExpectAbort $true
Test-RunnerCase -Name 'string count' -Fixture 'string-count' -ExpectedExit 1 -ExpectAbort $true
Test-RunnerCase -Name 'completed accounting mismatch' -Fixture 'accounting-mismatch' -ExpectedExit 1 -ExpectAbort $true

[Console]::Out.WriteLine("PARA_TEST_SUMMARY $($counts | ConvertTo-Json -Compress)")
if ($counts.failed -ne 0) {
    exit 1
}
