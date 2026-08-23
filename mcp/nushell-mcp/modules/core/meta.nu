# meta — provenance on a record. Metadata is data, not a separate practice.
# jobs imports `meta stamp` only.

use ./failure.nu ["failure fields"]
use ./value.nu ["value kind" "value columns"]

def stamp-meta [
    x
    verb: string
    tag: any = null
    elapsed: any = null
    ref: any = null
] {
    mut meta = {verb: $verb, at: (date now)}
    if $tag != null { $meta = $meta | insert tag $tag }
    if $elapsed != null { $meta = $meta | insert elapsed $elapsed }
    if $ref != null { $meta = $meta | insert ref $ref }
    let t = ($x | value kind)
    if $t == "record" {
        let base = (try { $x | reject meta } catch { $x })
        $base | merge {meta: $meta}
    } else {
        {meta: $meta, value: $x}
    }
}

# Provenance on a record: `{verb, at, tag?, elapsed?, ref?}`, or `null` when unstamped. Not nushell's `metadata` builtin.
# File stem is `meta`, so the noun is `main` (invoked as `meta` after `use`).
export def main []: any -> any {
    try {
        let x = $in
        if ($x | value kind) != "record" { return null }
        let m = (try { $x | get -o meta } catch { null })
        if $m == null { return null }
        if ($m | value kind) != "record" { return null }
        if "verb" not-in ($m | value columns) { return null }
        mut out = {verb: $m.verb, at: ($m.at? | default null)}
        if ("tag" in ($m | value columns)) { $out = $out | insert tag $m.tag }
        if ("elapsed" in ($m | value columns)) { $out = $out | insert elapsed $m.elapsed }
        if ("ref" in ($m | value columns)) { $out = $out | insert ref $m.ref }
        $out
    } catch {|e|
        let f = (failure fields $e)
        {ok: false, error: $f.error, trace: $f.trace}
    }
}

# Write a closed `meta` sub-record onto a record. Non-records wrap `{meta, value}`. Tables wrap, they are not merged per row. Stamping twice replaces, never nests. Bare `stamp` is refused.
export def "meta stamp" [
    --verb: string                          # Producing command, dotted (`jobs.spawn`, `xq`)
    --tag: string                           # Optional tag
    --elapsed: duration                     # Optional duration
    --ref: any                              # Optional pointer `{history: 7}` or `{tag: "sweep"}`
]: any -> any {
    try {
        if $verb == null {
            return {ok: false, error: "meta stamp: --verb required", trace: "meta stamp: --verb required"}
        }
        stamp-meta $in $verb $tag $elapsed $ref
    } catch {|e|
        let f = (failure fields $e)
        {ok: false, error: $f.error, trace: $f.trace}
    }
}
