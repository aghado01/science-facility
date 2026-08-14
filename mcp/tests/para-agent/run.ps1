[CmdletBinding()]
param(
    [string] $ManifestPath = (Join-Path $PSScriptRoot 'test-manifest.json'),
    [switch] $Live,
    [string[]] $Suite
)

$ErrorActionPreference = 'Stop'
$summaryPrefix = 'PARA_TEST_SUMMARY '

try {
    $resolvedManifest = (Resolve-Path -LiteralPath $ManifestPath).Path
    $manifestRoot = Split-Path -Parent $resolvedManifest
    $manifest = Get-Content -Raw -LiteralPath $resolvedManifest | ConvertFrom-Json -Depth 100

    if ($manifest.schema_version -ne 1) {
        throw "unsupported manifest schema_version '$($manifest.schema_version)'"
    }

    $bounded = @($manifest.bounded)
    $liveSuites = @($manifest.live)
    $suites = @($bounded)
    if ($Live) {
        $suites += $liveSuites
    }
    if ($Suite.Count -gt 0) {
        $wanted = @($Suite)
        $suites = @($suites | Where-Object { $wanted -contains $_.id })
    }
    if ($suites.Count -eq 0) {
        throw 'manifest selected zero suites'
    }
    if ($Live) {
        $liveIds = @($liveSuites | ForEach-Object { [string]$_.id })
        $selectedLive = @($suites | Where-Object { $liveIds -contains [string]$_.id })
        if ($selectedLive.Count -eq 0) {
            throw 'live mode selected zero manifest.live suites'
        }
    }

    $seen = @{}
    $countFields = @('discovered', 'completed', 'passed', 'failed', 'skipped', 'cancelled')
    $aggregate = [ordered]@{
        schema_version = 1
        suites = 0
        discovered = 0
        completed = 0
        passed = 0
        failed = 0
        skipped = 0
        cancelled = 0
        live = [bool]$Live
    }

    foreach ($suiteCase in $suites) {
        if ([string]::IsNullOrWhiteSpace($suiteCase.id)) {
            throw 'manifest suite has no id'
        }
        if ($seen.ContainsKey($suiteCase.id)) {
            throw "duplicate suite id '$($suiteCase.id)'"
        }
        $seen[$suiteCase.id] = $true

        $suitePath = Join-Path $manifestRoot $suiteCase.path
        if (-not (Test-Path -LiteralPath $suitePath -PathType Leaf)) {
            throw "listed suite '$($suiteCase.id)' is missing: $suitePath"
        }

        $runner = if ($suiteCase.runner) { [string]$suiteCase.runner } else { 'node-test' }
        $output = @()
        switch ($runner) {
            'node-test' {
                $reporter = Join-Path $PSScriptRoot 'support/test-reporter.mjs'
                if (-not (Test-Path -LiteralPath $reporter -PathType Leaf)) {
                    throw "test reporter is missing: $reporter"
                }
                $reporterUri = ([System.Uri]::new($reporter)).AbsoluteUri
                $output = @(& node '--test' '--test-concurrency=1' "--test-reporter=$reporterUri" $suitePath 2>&1)
            }
            'node-script' {
                $output = @(& node $suitePath 2>&1)
            }
            'powershell' {
                $pwsh = Join-Path $PSHOME 'pwsh.exe'
                if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) {
                    $pwsh = Join-Path $PSHOME 'pwsh'
                }
                $output = @(& $pwsh -NoProfile -ExecutionPolicy Bypass -File $suitePath 2>&1)
            }
            default {
                throw "suite '$($suiteCase.id)' has unsupported runner '$runner'"
            }
        }
        $exitCode = $LASTEXITCODE
        foreach ($line in $output) {
            [Console]::Out.WriteLine("[$($suiteCase.id)] $line")
        }
        if ($exitCode -ne 0) {
            throw "suite '$($suiteCase.id)' child exited $exitCode"
        }

        $terminal = @($output | Where-Object { ([string]$_).StartsWith($summaryPrefix, [StringComparison]::Ordinal) })
        if ($terminal.Count -ne 1) {
            throw "suite '$($suiteCase.id)' emitted $($terminal.Count) terminal summaries"
        }
        $summaryJson = ([string]$terminal[0]).Substring($summaryPrefix.Length)
        $summary = $summaryJson | ConvertFrom-Json -Depth 20
        if ($summary.schema_version -ne 1) {
            throw "suite '$($suiteCase.id)' emitted an unsupported summary"
        }
        $counts = @{}
        foreach ($field in $countFields) {
            $property = $summary.PSObject.Properties[$field]
            if ($null -eq $property) {
                throw "suite '$($suiteCase.id)' summary is missing required count '$field'"
            }
            $value = $property.Value
            if ($value -is [bool] -or -not ($value -is [ValueType])) {
                throw "suite '$($suiteCase.id)' summary count '$field' is not an integer"
            }
            try {
                $number = [decimal]$value
            }
            catch {
                throw "suite '$($suiteCase.id)' summary count '$field' is not an integer"
            }
            if ($number -lt 0 -or $number -ne [decimal]::Truncate($number) -or $number -gt [long]::MaxValue) {
                throw "suite '$($suiteCase.id)' summary count '$field' must be a nonnegative integer"
            }
            $counts[$field] = [long]$number
        }
        if ($counts.discovered -le 0) {
            throw "suite '$($suiteCase.id)' discovered zero tests"
        }
        if ($counts.discovered -ne $counts.completed) {
            throw "suite '$($suiteCase.id)' discovered/completed mismatch: $($counts.discovered)/$($counts.completed)"
        }
        $accounted = $counts.passed + $counts.failed + $counts.skipped + $counts.cancelled
        if ($accounted -ne $counts.completed) {
            throw "suite '$($suiteCase.id)' completed/accounted mismatch: $($counts.completed)/$accounted"
        }
        if ($counts.failed -ne 0 -or $counts.cancelled -ne 0) {
            throw "suite '$($suiteCase.id)' reported failed or cancelled tests"
        }
        if ($Live -and $counts.skipped -ne 0) {
            throw "live-mode suite '$($suiteCase.id)' reported $($counts.skipped) skipped tests"
        }

        $aggregate.suites += 1
        foreach ($field in $countFields) {
            $aggregate[$field] += $counts[$field]
        }
    }

    [Console]::Out.WriteLine("PARA_MANIFEST_SUMMARY $($aggregate | ConvertTo-Json -Compress)")
    exit 0
}
catch {
    [Console]::Error.WriteLine("SUITE-ABORTED $($_.Exception.Message)")
    exit 1
}
