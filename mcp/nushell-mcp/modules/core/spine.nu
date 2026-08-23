# spine — where the mass is, over one column. rg will import this without schema/views.

use ./failure.nu ["failure fields"]
use ./value.nu ["value columns"]

# `{key, n}`, sorted n desc then key asc. Missing column → `[]`.
# File stem is `spine`, so the noun is `main` (invoked as `spine` after `use`).
export def main [
    column: string                          # Column to group
    --top: int                              # Keep the first N rows after sort
]: any -> any {
    try {
        let x = $in
        let keys = ($x | value columns)
        if not ($column in $keys) { return [] }
        let g = ($x | group-by {|row| $row | get $column} --to-table)
        let rows = (
            $g | each {|r|
                let key = (try { $r | reject items | values | first } catch { null })
                {key: $key, n: ($r.items | length)}
            }
        )
        let labeled = (
            $rows | each {|r| $r | insert _s (try { $r.key | to nuon --raw } catch { "" }) }
        )
        let ns = ($labeled | get n | uniq | sort --reverse)
        let sorted = (
            $ns | each {|nv|
                $labeled | where n == $nv | sort-by _s
            } | flatten | reject _s
        )
        if $top != null { $sorted | first $top } else { $sorted }
    } catch {|e|
        let f = (failure fields $e)
        {ok: false, error: $f.error, trace: $f.trace}
    }
}
