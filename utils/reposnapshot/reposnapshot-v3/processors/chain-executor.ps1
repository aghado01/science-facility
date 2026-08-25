# See [chain-executor.md](docs/chain-executor.md) for docstring
param(
    [object]    $Item,
    [hashtable] $Plan,
    [System.Collections.Concurrent.ConcurrentBag[string]] $ErrorBag,
    [int]       $Index
)

$current = $Item

foreach ($step in $Plan.Steps) {
    if ($current -is [System.Management.Automation.PSObject] -and
        $current.PSObject.Properties['_ChainHalt']) { break }

    try {
        $current = & $step.Fn $current $step.Config
    }
    catch {
        $ErrorBag.Add("Item [$Index] step '$($step.Key)': $($_.Exception.Message)")
        break
    }
}

return $current
