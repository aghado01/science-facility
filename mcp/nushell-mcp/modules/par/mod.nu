# par — data-plane map. Pipeline in, table out, no handles.
# Wraps `par-each` with a budgeted `--threads` grant and a closed row shape.
# Nested `par` inside `jobs spawn` can oversubscribe; policy is enforced at REPL dispatch only.

const SELF_DIR = (path self | path dirname)

# `shape` for the one `bytes` definition. Overlay `use *` does not leak into this module.
use core/census.nu [shape]
use core/outcome.nu ["outcome project"]
use core/execution.nu ["execution context" "execution worker-env"]

# --- host facts / knobs -------------------------------------------------------

def discover-cores [] {
    let n = (try { sys cpu | get name | length } catch { 0 })
    if $n >= 1 { return $n }
    let win = ($env.NUMBER_OF_PROCESSORS? | default "")
    if ($win | is-not-empty) {
        return ($win | into int)
    }
    error make {
        msg: "cannot discover logical cores"
        label: "sys cpu empty and NUMBER_OF_PROCESSORS unset"
    }
}

def load-policy []: nothing -> record {
    let p = ($SELF_DIR | path join policy.json)
    if ($p | path exists) {
        open $p
    } else {
        {max_workers: null, reserved_cores: 2, min_items_per_worker: 4, max_inline_bytes: null}
    }
}

# Ceiling: explicit max (clamped to cores), else cores - reserved (>= 1 worker).
def compute-ceiling [
    cores: int
    reserved: int
    max_workers: any
]: nothing -> record {
    let reserved = (if $cores <= 1 { 0 } else { [$reserved, ($cores - 1)] | math min })
    let auto = $cores - $reserved
    if $max_workers == null {
        {ceiling: $auto, clamped: false, warning: null}
    } else {
        let req = ($max_workers | into int)
        if $req > $cores {
            {
                ceiling: $cores
                clamped: true
                warning: $"par budget: requested ($req) threads clamped to ($cores) logical cores"
            }
        } else {
            let ceiling = (if $req < 1 { 1 } else { $req })
            {ceiling: $ceiling, clamped: false, warning: null}
        }
    }
}

def freeze-nu-par []: nothing -> record {
    let knobs = (load-policy)
    let cores = (discover-cores)
    let reserved = ($knobs.reserved_cores | default 2)
    let cap = (compute-ceiling $cores $reserved $knobs.max_workers)
    {
        cores: $cores
        os: $nu.os-info.name
        max_workers: $knobs.max_workers
        reserved_cores: $reserved
        min_items_per_worker: ($knobs.min_items_per_worker | default 4)
        max_inline_bytes: $knobs.max_inline_bytes
        ceiling: $cap.ceiling
        policy: (if $knobs.max_workers == null { "auto" } else { "explicit" })
    }
}

def short-error [msg: string]: nothing -> string {
    let line = ($msg | lines | first | default "")
    if ($line | str length) <= 240 { $line } else { $line | str substring 0..239 }
}

def resolve-inline-cap []: nothing -> int {
    let k = ($env.NU_PAR?.max_inline_bytes? | default null)
    if $k != null {
        let d = ($k | describe)
        if $d == "int" { $k } else if $d == "filesize" { $k | into int } else { $k | into filesize | into int }
    } else if ($env.NU_MCP_OUTPUT_LIMIT? != null) {
        try { $env.NU_MCP_OUTPUT_LIMIT | into filesize | into int } catch { 20000 }
    } else {
        20000
    }
}

# Inline / query cap. `$env.NU_PAR.max_inline_bytes` if set, else `NU_MCP_OUTPUT_LIMIT`, else 20000.
# One resolver: `par emit`, in-hand `read`, and `jobs read` all call this.
export def "par cap" []: nothing -> int {
    resolve-inline-cap
}

export-env {
    if ($env.NU_PAR? == null) {
        $env.NU_PAR = (freeze-nu-par)
    }
}

# --- exports ------------------------------------------------------------------

# Resolve a worker grant. Pure given its arguments; missing flags fall back to $env.NU_PAR.
# Returns {grant, ceiling, cores, graded, clamped, warning}.
export def "par budget" [
    items: int                              # Input length (maps). Spawn uses ceiling only.
    --threads: int                          # Explicit max workers for this dispatch (request, not grant)
    --cores: int                            # Override discovered cores (tests)
    --reserved-cores: int                   # Override reserved_cores
    --min-items-per-worker: int             # Override grade K (default 4)
]: nothing -> record {
    let par = ($env.NU_PAR? | default {})
    let cores = (if $cores != null { $cores } else if $par.cores? != null { $par.cores } else { discover-cores })
    let reserved = (
        if $reserved_cores != null { $reserved_cores }
        else if $par.reserved_cores? != null { $par.reserved_cores }
        else { 2 }
    )
    let k = (
        if $min_items_per_worker != null { $min_items_per_worker }
        else if $par.min_items_per_worker? != null { $par.min_items_per_worker }
        else { 4 }
    )
    let explicit = (
        if $threads != null { $threads }
        else { $par.max_workers? | default null }
    )
    let cap = (compute-ceiling $cores $reserved $explicit)
    let graded = (if $items < 1 { 1 } else { (($items / $k) | math ceil | into int) })
    mut grant = ([$cap.ceiling $graded $items] | math min)
    if $grant < 1 { $grant = 1 }
    {
        grant: $grant
        ceiling: $cap.ceiling
        cores: $cores
        graded: $graded
        clamped: $cap.clamped
        warning: $cap.warning
    }
}

# Parallel map. One row per input, input order (opt out with --no-keep-order).
# Row: {index, ok, item, value, error, elapsed}. Fail-soft: a dead item is a row; the map continues.
# A thrown closure is `ok: false`, `value: null`. A returned declared failure
# (`{ok: false, ...}` or an outcome table with failed rows) is `ok: false` with
# the original value retained (tag / retrieve / meta stay on `value`). A returned
# failure never throws, never cancels siblings, never punches a hole.
# --threads is a request (MaxWorkers), not a grant — resolve-budget clamps it.
# Large maps belong in `jobs spawn { $data | par {|row| ...} }`, then inspect/read.
# Do not return per-row handles. Native `par-each --threads` bypasses policy; use this.
export def main [
    fn: closure                             # Closure over each input cell (`{|row| ...}`)
    --threads: int                          # Requested max workers for this dispatch
    --no-keep-order                         # Opt out of input order (completion order is not a result)
]: any -> table {
    let items = ($in | enumerate)
    if ($items | is-empty) { return [] }
    let n = ($items | length)
    let b = (
        if $threads != null {
            par budget $n --threads $threads
        } else {
            par budget $n
        }
    )
    if $b.warning != null { print -e $b.warning }
    let in_job = (execution context).in_job
    let work = {|row|
        let t0 = (date now)
        let r = (try {
            let value = (do $fn $row.item)
            let proj = ($value | outcome project)
            {ok: $proj.ok, value: $value, error: $proj.error}
        } catch {|e|
            {ok: false, value: null, error: (short-error $e.msg)}
        })
        {
            index: $row.index
            ok: $r.ok
            item: $row.item
            value: $r.value
            error: $r.error
            elapsed: ((date now) - $t0)
        }
    }
    let we = (if $in_job { execution worker-env --in-job } else { execution worker-env })
    with-env $we {
        if $no_keep_order {
            $items | par-each --threads $b.grant $work
        } else {
            $items | par-each --threads $b.grant --keep-order $work
        }
    }
}

# Query envelope: findings + census. `findings` omitted when over max_inline_bytes.
# Contract for wrappers. Truncate on bytes, not rows. n is row count (flatten first if you need hit count).
# `bytes` is `shape`'s definition.
export def "par emit" []: any -> record {
    let findings = $in
    let n = (if ($findings | is-empty) { 0 } else { $findings | length })
    let cols = (try { $findings | columns } catch { [] })
    let has_ok = ("ok" in $cols)
    let n_err = (if $has_ok and $n > 0 { $findings | where {|r| $r.ok == false } | length } else { 0 })
    let n_ok = $n - $n_err
    let elapsed = (
        if ("elapsed" in $cols) and $n > 0 {
            try { $findings | get elapsed | compact | math max } catch { null }
        } else { null }
    )
    let bytes = ($findings | shape | get bytes)
    let cap = (par cap)
    let truncated = (if $bytes == null { true } else { $bytes > $cap })
    let envelope = {
        ok: ($n_err == 0)
        n: $n
        n_ok: $n_ok
        n_err: $n_err
        elapsed: $elapsed
        bytes: $bytes
        truncated: $truncated
    }
    if $truncated { $envelope } else { $envelope | insert findings $findings }
}
