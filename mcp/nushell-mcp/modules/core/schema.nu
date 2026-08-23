# schema — structural profile of a population. One unit; do not split subcommands.

use ./failure.nu ["failure fields"]
use ./value.nu ["value kind" "value columns" "value nuon"]

def percentile-95 [nums]: nothing -> any {
    let n = (try { $nums | length } catch { 0 })
    if $n == 0 { return null }
    let s = ($nums | sort)
    mut idx = ((($n * 95) / 100) | math ceil | into int) - 1
    if $idx < 0 { $idx = 0 }
    if $idx >= $n { $idx = $n - 1 }
    $s | get $idx
}

def split-path [p: string]: nothing -> list<string> {
    $p
    | str replace --all "[]" ".[]"
    | split row "."
    | where {|x| $x != ""}
}

def values-at [x, parts: list<string>] {
    if ($parts | is-empty) { return [$x] }
    let p = ($parts | first)
    let rest = ($parts | skip 1)
    let t = ($x | value kind)
    if $p == "[]" {
        if $t in ["list" "table"] {
            $x | each {|el| values-at $el $rest } | flatten
        } else { [] }
    } else if $t == "record" {
        let keys = ($x | value columns)
        if $p in $keys {
            values-at ($x | get $p) $rest
        } else { [] }
    } else { [] }
}

def walk-paths [x, prefix: string] {
    let t = ($x | value kind)
    if $t == "record" {
        $x | value columns | each {|k|
            let p = (if $prefix == "" { $k } else { $"($prefix).($k)" })
            let v = (try { $x | get $k } catch { null })
            [{path: $p, type: ($v | value kind)}] ++ (walk-paths $v $p)
        } | flatten
    } else if $t in ["list" "table"] {
        let p = (if $prefix == "" { "[]" } else { $"($prefix)[]" })
        let n = (try { $x | length } catch { 0 })
        if $n == 0 {
            []
        } else {
            $x | each {|el|
                [{path: $p, type: ($el | value kind)}] ++ (walk-paths $el $p)
            } | flatten
        }
    } else {
        []
    }
}

def population-members [x] {
    let t = ($x | value kind)
    if $t in ["list" "table"] {
        let n = (try { $x | length } catch { 0 })
        if $n == 0 { [] } else { $x | each {|m| $m} }
    } else {
        [$x]
    }
}

# Structural profile of a population. Table rows / list elements / a record is a population of one.
# Paths dotted, lists as `[]` (`body.items[].id`). `{path, types, coverage, hits, records}`, lexical order.
# File stem is `schema`, so the noun is `main` (invoked as `schema` after `use`).
export def main []: any -> any {
    try {
        let x = $in
        if ($x | value kind) == "closure" {
            let info = ($x | value nuon)
            return {
                ok: false
                error: ($info.error | default "cannot schema a closure")
                trace: ($info.trace | default "cannot schema a closure")
            }
        }
        let members = (population-members $x)
        let records = ($members | length)
        if $records == 0 { return [] }
        let obs = (
            $members | enumerate | each {|it|
                walk-paths $it.item "" | each {|p| $p | insert record $it.index }
            } | flatten
        )
        if ($obs | is-empty) { return [] }
        let paths = ($obs | get path | uniq | sort)
        $paths | each {|p|
            let rows = ($obs | where path == $p)
            let types = ($rows | get type | uniq | sort | str join "|")
            let hits = ($rows | length)
            let recs = ($rows | get record | uniq | length)
            {
                path: $p
                types: $types
                coverage: (($recs / $records) * 100)
                hits: $hits
                records: $recs
            }
        }
    } catch {|e|
        let f = (failure fields $e)
        {ok: false, error: $f.error, trace: $f.trace}
    }
}

# Diff two schema tables: `{path, status: added|removed|changed, before?, after?}`.
export def "schema diff" [other: any]: any -> any {
    try {
        let before = $in
        let after = $other
        let bp = (try { $before | get path } catch { [] })
        let ap = (try { $after | get path } catch { [] })
        let all = ($bp ++ $ap | uniq | sort)
        $all | each {|p|
            let b = (try { $before | where path == $p | get 0 } catch { null })
            let a = (try { $after | where path == $p | get 0 } catch { null })
            if $b == null {
                {path: $p, status: "added", after: $a.types}
            } else if $a == null {
                {path: $p, status: "removed", before: $b.types}
            } else if $b.types != $a.types {
                {path: $p, status: "changed", before: $b.types, after: $a.types}
            } else { null }
        } | where {|r| $r != null }
    } catch {|e|
        let f = (failure fields $e)
        {ok: false, error: $f.error, trace: $f.trace}
    }
}

# Validate `$in` (a population) against a schema profile. `{ok, violations}`. Never throws.
export def "schema check" [profile: any]: any -> record {
    try {
        let x = $in
        let members = (population-members $x)
        let paths = (try { $profile | get path } catch { [] })
        mut violations = []
        for it in ($members | enumerate) {
            for p in $paths {
                let expected = (try { $profile | where path == $p | first | get types } catch { "" })
                let want = ($expected | split row "|" | where {|t| $t != ""})
                let gotvals = (values-at $it.item (split-path $p))
                if ($gotvals | is-empty) {
                    if not ("nothing" in $want) {
                        $violations = ($violations | append {
                            path: $p
                            expected: $expected
                            got: "nothing"
                            record: $it.index
                        })
                    }
                } else {
                    for v in $gotvals {
                        let got = ($v | value kind)
                        if not ($got in $want) {
                            $violations = ($violations | append {
                                path: $p
                                expected: $expected
                                got: $got
                                record: $it.index
                            })
                        }
                    }
                }
            }
        }
        {ok: ($violations | is-empty), violations: $violations}
    } catch {|e|
        let f = (failure fields $e)
        {ok: false, violations: [], error: $f.error, trace: $f.trace}
    }
}

# Length stats for string/list leaves at `path`. Missing path → `n: 0`.
export def "schema stats" [path: string]: any -> record {
    try {
        let members = (population-members $in)
        let parts = (split-path $path)
        let lens = (
            $members | each {|m|
                values-at $m $parts | each {|v|
                    let t = ($v | value kind)
                    if $t == "string" {
                        try { $v | str length } catch { null }
                    } else if $t in ["list" "table"] {
                        try { $v | length } catch { null }
                    } else { null }
                }
            } | flatten | where {|n| $n != null }
        )
        let n = ($lens | length)
        if $n == 0 {
            {path: $path, n: 0, len_min: null, len_max: null, len_avg: null, len_p95: null}
        } else {
            {
                path: $path
                n: $n
                len_min: ($lens | math min)
                len_max: ($lens | math max)
                len_avg: ($lens | math avg)
                len_p95: (percentile-95 $lens)
            }
        }
    } catch {|e|
        let f = (failure fields $e)
        {ok: false, path: $path, n: 0, len_min: null, len_max: null, len_avg: null, len_p95: null, error: $f.error, trace: $f.trace}
    }
}
