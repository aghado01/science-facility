The shortest correct model is three passes: **enable**, **route**, **sort**. `Group`/`Rank` already *are* the spine, so you do not need a separate `Spine` array. You also do not get one chain for the run — `$strip` occupies one slot that fans out per file class.

Against this `user-config.json` (`IncludeProcessors` + `*.ps1`/`*.psm1`) that resolves to:

```
powershell: file-read → rs.ps.strip → rs-indent → rs-whitespace → rs-content_meta
default:    file-read → rs-indent → rs-whitespace → rs-content_meta
```

Add `.cs` to the corpus and a `csharp` variant appears with `rs.cs.strip` in the same Group 2 slot. Those two strippers never co-exist on one file.

### 1. Enable (filter + Requires closure)

`IncludeProcessors` is a set, not an order. Union `Default: true` (`file-read`), then close `Requires`:

```powershell
$seq   = Get-Content -Raw .\processors\sequencing.json | ConvertFrom-Json -AsHashtable
$cfg   = Get-Content -Raw .\user-config.json          | ConvertFrom-Json -AsHashtable
$procs = $seq.Processors

$wanted = [System.Collections.Generic.HashSet[string]]::new([string[]]$cfg.IncludeProcessors)
foreach ($k in $procs.Keys) { if ($procs[$k].Default) { [void]$wanted.Add($k) } }
do {
    $n = $wanted.Count
    foreach ($k in @($wanted)) {
        foreach ($r in @($procs[$k].Requires)) { [void]$wanted.Add($r) }
    }
} while ($wanted.Count -gt $n)
```

That yields `{ file-read, $strip, rs-indent, rs-whitespace, rs-content_meta }`. Array position in the config is ignored.

### 2. Route (slice `$strip` against crawler `Extension`)

Fixed keys map to `processors\<key>.ps1`. `$strip` does not — there is no `$strip.ps1`. `Routing.$strip` names the real files, and crawler already stamped `Extension` (leading-dot, e.g. `.ps1`) on every descriptor. Use that; do not re-derive from the path.

```powershell
$dotless = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]($eligible.Extension | ForEach-Object { $_.TrimStart('.').ToLowerInvariant() })
)

# languages actually present
$classes = [System.Collections.Generic.List[string]]::new()
[void]$classes.Add('default')
foreach ($token in $seq.Routing.Keys) {
    if (-not $wanted.Contains($token)) { continue }
    foreach ($lang in $seq.Routing[$token].GetEnumerator()) {
        $hit = $false
        foreach ($e in $lang.Value.extensions) {
            if ($dotless.Contains([string]$e)) { $hit = $true; break }
        }
        if ($hit) { [void]$classes.Add($lang.Key) }
    }
}
```

Per class, walk `$wanted` and **splice** an unresolved token rather than leaving a hole:

```powershell
function Resolve-Steps([string]$class) {
    foreach ($k in $wanted) {
        $meta = $procs[$k]
        $file = "$k.ps1"
        if ($seq.Routing.Contains($k)) {
            if ($class -eq 'default' -or -not $seq.Routing[$k].Contains($class)) { continue }
            $file = $seq.Routing[$k][$class].processor   # rs.ps.strip.ps1
        }
        [pscustomobject]@{
            Key   = [IO.Path]::GetFileNameWithoutExtension($file)
            File  = $file
            Group = [int]$meta.Group
            Rank  = [int]$meta.Rank
        }
    }
}
```

`required: true` on a route is a disk check when `$strip` is enabled (`processors\rs.ps.strip.ps1` must exist). It does not force that language into every chain. Bind only classes whose extensions actually appear.

### 3. Sort (canon)

```powershell
$variants = [ordered]@{}
foreach ($class in $classes) {
    $variants[$class] = @(Resolve-Steps $class | Sort-Object Group, Rank)
}
```

Cast `Group`/`Rank` to `[int]` — they are strings in the JSON, and string sort will eventually put `"10"` before `"2"`. `Sort-Object` is the right tool here: it is stable, so equal `(Group, Rank)` stays in input order, which you should not rely on. Two `$strip` members sharing Group 2 / Rank 0 is fine because routing makes them mutually exclusive.

ISS registration is the **union of `Key`s across variants**. Dispatch is a per-file lookup: `Extension` → class → frozen step list. That is the whole compiler.

### Things that will bite

- **`$strip` is data.** In PowerShell `"$strip"` interpolates to empty. Keep the token in JSON / hashtable keys / single-quoted strings.
- **`IncludeProcessors` is not wired yet.** `rs.core.user.ps1` still reads `Processors` as a literal ordered list of concrete keys (`rs.ps.strip`, not `$strip`) and hard-prepends `file-read`. The recipe above is the replacement for that block.
- **Do not flatten both strippers into one execution chain.** The union list is what you load; each file runs one dense variant.