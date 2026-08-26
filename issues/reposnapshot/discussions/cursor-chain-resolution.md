The occupancy test is the algorithm. The hair is that `Resolve-Routing` answers occupancy, then `Resolve-Variants` **joins that answer back onto the spine**.

What you have now:

1. For each unique extension, filter `Routes` and collect `(Slot, Key)` pairs.
2. Name the variant by joining those keys with `|`.
3. Walk `Enabled` again and `$pairs | Where-Object { $_.Slot -eq $slot }` to rebuild the chain.

Step 3 exists only because step 1 threw the spine away. The comment that nothing may parse the `|` key is the tell: internment was encoded as a string join, then you had to warn yourself not to treat it as data.

The walk you had in mind is one pass. Sort the enabled set once, occupancy-test each routed slot, splice on miss:

```powershell
function Resolve-Chain($Sequence, $Enabled, [string]$Extension)
{
    $ext = '.' + $Extension.TrimStart('.').ToLowerInvariant()
    $steps = foreach ($slot in ($Enabled | Sort-Object { $Sequence.Processors[$_].Group }, { $Sequence.Processors[$_].Rank }))
    {
        $meta = $Sequence.Processors[$slot]
        if ($meta.IsRouted)
        {
            $hit = @($meta.Routes | Where-Object { $ext -in $_.Extensions })
            if ($hit.Count -eq 0) { continue }          # splice
            $key = $hit[0].Key
        }
        else { $key = $meta.Key }

        [pscustomobject]@{ Key = $key; Slot = $slot; Config = @{} }
    }
    @($steps)
}
```

That is the helper: `$ext -in $_.Extensions` on the JSON records. No pair list, no `|` identity, no second join.

Internment stays, but it is a **cache over unique extensions**, not a relation:

```powershell
$variants = @{}
$extMap = @{}
foreach ($ext in $uniqueExts)
{
    $chain = Resolve-Chain $seq $enabled $ext
    $id = [string]($variants.Keys | Where-Object { -not (Compare-Object $variants[$_].Key $chain.Key) } | Select-Object -First 1)
    if (-not $id)
    {
        $id = [guid]::NewGuid().ToString('N')   # opaque; dispatch never prints it
        $variants[$id] = $chain
    }
    $extMap[$ext] = $id
}
```

`.ps1` and `.psm1` still share a chain because `Compare-Object` on the Key lists agrees, not because both stringify to `rs.ps.strip`. Dispatch stays `Extension → intern id → frozen steps`. Workers never walk Routing.

`Resolve-Routing` + `Resolve-Variants` collapse into `Resolve-Chain` plus that intern loop. Compile still runs it over the corpus extension set ingest already collected — not per file. Per-item work is the dictionary lookup you already have in `Invoke-Plan`.

The `|` keys in the tests (`ExtensionMap['.ps1'] -eq 'rs.ps.strip'`) are asserting the intern label, not the chain. After the collapse, assert the chain (`file_read > rs.ps.strip > …`) and that sibling extensions point at the same intern id. The label itself is not a fact.