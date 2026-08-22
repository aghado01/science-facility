# dataspection — disciplined access to a value in hand.
# Census before body, receipts before disclosure, bounded views, no silent omission.
# `use dataspection *`. Does not export `inspect` (nushell's builtin stays).
# `read` is `--env` and stashes over cap through `jobs stash`; other commands are pure.

# --- helpers ------------------------------------------------------------------

def norm-type [x]: nothing -> string {
    let d = (try { $x | describe --no-collect } catch { "other" })
    if ($d | str starts-with "table") { "table"
    } else if ($d | str starts-with "list") { "list"
    } else if ($d | str starts-with "record") { "record"
    } else if $d in [
        "string" "int" "float" "bool" "datetime" "duration"
        "filesize" "nothing" "binary" "closure"
    ] { $d
    } else { "other" }
}

def catch-fields [e]: nothing -> record {
    let msg = (try { $e.msg } catch { "error" })
    let line = (try { $msg | lines | first } catch { $msg }) | default $msg
    let short = (
        if ($line | str length) <= 240 { $line } else { $line | str substring ..<240 }
    )
    let rendered = (try { $e.rendered } catch { "" }) | default ""
    let debug = (try { $e.debug } catch { "" }) | default ""
    let trace = (
        if ($rendered | str length) > 0 { $rendered
        } else if ($debug | str length) > 0 { $debug
        } else { $short }
    )
    {error: $short, trace: $trace}
}

def nuon-info [x]: nothing -> record {
    try {
        let s = ($x | to nuon --raw)
        {
            bytes: ($s | str length --utf-8-bytes)
            nuon: $s
            error: null
            trace: null
        }
    } catch {|e|
        let f = (catch-fields $e)
        {bytes: null, nuon: "", error: $f.error, trace: $f.trace}
    }
}

def head-of [s: string]: nothing -> string {
    let one = ($s | str replace --all "\n" " " | str replace --all "\r" " ")
    if ($one | str length) <= 80 { $one } else { $one | str substring ..<80 }
}

def resolve-inline-cap []: nothing -> int {
    let k = ($env.NU_PAR?.max_inline_bytes? | default null)
    if $k != null {
        let d = ($k | describe)
        if $d == "int" { $k
        } else if $d == "filesize" { $k | into int
        } else { try { $k | into filesize | into int } catch { 20000 } }
    } else if ($env.NU_MCP_OUTPUT_LIMIT? != null) {
        try { $env.NU_MCP_OUTPUT_LIMIT | into filesize | into int } catch { 20000 }
    } else {
        20000
    }
}

def cols-of [x]: nothing -> list<string> {
    try { $x | columns } catch { [] }
}

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
    let t = (norm-type $x)
    if $t == "record" {
        let base = (try { $x | reject meta } catch { $x })
        $base | merge {meta: $meta}
    } else {
        {meta: $meta, value: $x}
    }
}

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
    let t = (norm-type $x)
    if $p == "[]" {
        if $t in ["list" "table"] {
            $x | each {|el| values-at $el $rest } | flatten
        } else { [] }
    } else if $t == "record" {
        let keys = (cols-of $x)
        if $p in $keys {
            values-at ($x | get $p) $rest
        } else { [] }
    } else { [] }
}

def walk-paths [x, prefix: string] {
    let t = (norm-type $x)
    if $t == "record" {
        cols-of $x | each {|k|
            let p = (if $prefix == "" { $k } else { $"($prefix).($k)" })
            let v = (try { $x | get $k } catch { null })
            [{path: $p, type: (norm-type $v)}] ++ (walk-paths $v $p)
        } | flatten
    } else if $t in ["list" "table"] {
        let p = (if $prefix == "" { "[]" } else { $"($prefix)[]" })
        let n = (try { $x | length } catch { 0 })
        if $n == 0 {
            []
        } else {
            $x | each {|el|
                [{path: $p, type: (norm-type $el)}] ++ (walk-paths $el $p)
            } | flatten
        }
    } else {
        []
    }
}

def population-members [x] {
    let t = (norm-type $x)
    if $t in ["list" "table"] {
        let n = (try { $x | length } catch { 0 })
        if $n == 0 { [] } else { $x | each {|m| $m} }
    } else {
        [$x]
    }
}

def shape-core [x]: nothing -> record {
    let t = (norm-type $x)
    let info = (nuon-info $x)
    let length = (
        if $t in ["table" "list"] {
            try { $x | length } catch { null }
        } else if $t == "string" {
            try { $x | str length --utf-8-bytes } catch { null }
        } else { null }
    )
    mut rec = {
        type: $t
        length: $length
        bytes: $info.bytes
        head: (head-of $info.nuon)
    }
    if $t == "table" {
        let row0 = (try { $x | get 0 } catch { null })
        let columns = (
            cols-of $x | each {|n|
                let vt = (if $row0 == null { "nothing" } else { norm-type (try { $row0 | get $n } catch { null }) })
                {name: $n, type: $vt}
            }
        )
        mut nulls = 0
        for col in (cols-of $x) {
            let cells = (try { $x | get $col } catch { [] })
            for v in $cells {
                if (norm-type $v) == "nothing" { $nulls = $nulls + 1 }
            }
        }
        $rec = ($rec | insert columns $columns | insert nulls $nulls)
    } else if $t == "record" {
        let columns = (
            cols-of $x | each {|n|
                {name: $n, type: (norm-type (try { $x | get $n } catch { null }))}
            }
        )
        $rec = ($rec | insert columns $columns)
        if "ok" in (cols-of $x) {
            $rec = ($rec | insert ok (try { $x | get ok } catch { null }))
        }
    }
    if $info.error != null {
        $rec = ($rec | insert error $info.error | insert trace $info.trace)
    }
    $rec
}

def shape-each-row [index: int, item] {
    let s = (shape-core $item)
    let isrec = (norm-type $item) == "record"
    let keys = (if $isrec { cols-of $item } else { [] })
    let okv = (if $isrec and ("ok" in $keys) { try { $item | get ok } catch { null } } else { null })
    let verb = (if $isrec { try { $item | get -o meta.verb } catch { null } } else { null })
    mut row = {
        index: $index
        type: $s.type
        length: $s.length
        bytes: $s.bytes
        ok: $okv
        verb: $verb
        head: $s.head
    }
    if ("error" in (cols-of $s)) {
        $row = ($row | insert error $s.error | insert trace $s.trace)
    }
    $row
}

def already-clipped-str [s: string]: nothing -> bool {
    ($s | str contains "… [+")
}

def already-clipped-list [xs]: nothing -> bool {
    let n = (try { $xs | length } catch { 0 })
    if $n == 0 { return false }
    let last = (try { $xs | last } catch { null })
    if (norm-type $last) != "string" { return false }
    $last =~ '^\[\+\d+ more\]$'
}

def clip-str [s: string, chars: int, mode: string]: nothing -> string {
    if (already-clipped-str $s) { return $s }
    let len = ($s | str length)
    if $len <= $chars { return $s }
    let omitted = $len - $chars
    let mark = $"… [+($omitted) chars]"
    if $mode == "tail" {
        let start = $len - $chars
        $"($mark)($s | str substring $start..<($len))"
    } else if $mode == "sandwich" {
        let left = $chars // 2
        let right = $chars - $left
        let start = $len - $right
        $"($s | str substring ..<($left))($mark)($s | str substring $start..<($len))"
    } else {
        $"($s | str substring ..<($chars))($mark)"
    }
}

def clip-list [xs, items: int, mode: string] {
    if (already-clipped-list $xs) { return $xs }
    let n = (try { $xs | length } catch { 0 })
    if $n <= $items { return $xs }
    let k = $n - $items
    let mark = $"[+($k) more]"
    if $mode == "tail" {
        [$mark] ++ ($xs | last $items)
    } else if $mode == "sandwich" {
        let left = $items // 2
        let right = $items - $left
        (try { $xs | first $left } catch { [] }) ++ [$mark] ++ (try { $xs | last $right } catch { [] })
    } else {
        (try { $xs | first $items } catch { [] }) ++ [$mark]
    }
}

def preview-impl [x, chars: int, items: int, mode: string] {
    let t = (norm-type $x)
    if $t == "string" {
        clip-str $x $chars $mode
    } else if $t == "record" {
        cols-of $x | reduce --fold {} {|k, acc|
            $acc | insert $k (preview-impl (try { $x | get $k } catch { null }) $chars $items $mode)
        }
    } else if $t in ["list" "table"] {
        let xs = (try { $x | each {|el| preview-impl $el $chars $items $mode} } catch { [] })
        clip-list $xs $items $mode
    } else {
        $x
    }
}

def fail-shape [e]: nothing -> record {
    let f = (catch-fields $e)
    {type: "other", length: null, bytes: null, head: "", error: $f.error, trace: $f.trace}
}

# --- exports ------------------------------------------------------------------

# Census of one value. Always fits. `{type, length, bytes, head}` plus `columns`/`nulls` when they apply.
# `bytes` is NUON-serialized UTF-8 length — the one definition for the layer. Unserializable → `bytes: null` + `error`/`trace`.
export def shape []: any -> record {
    try {
        shape-core $in
    } catch {|e|
        fail-shape $e
    }
}

# One census row per element. `index` is the input position (`$history | shape each` → the `$history` index).
# `ok` and `verb` are lifted from the element when present, otherwise null. Empty list → empty table.
export def "shape each" []: any -> any {
    try {
        let x = $in
        let t = (norm-type $x)
        if $t in ["list" "table"] {
            let n = (try { $x | length } catch { 0 })
            if $n == 0 { return [] }
            $x | enumerate | each {|it| shape-each-row $it.index $it.item }
        } else {
            [ (shape-each-row 0 $x) ]
        }
    } catch {|e|
        let f = (catch-fields $e)
        {ok: false, error: $f.error, trace: $f.trace}
    }
}

# Structural profile of a population. Table rows / list elements / a record is a population of one.
# Paths dotted, lists as `[]` (`body.items[].id`). `{path, types, coverage, hits, records}`, lexical order.
export def schema []: any -> any {
    try {
        let x = $in
        if (norm-type $x) == "closure" {
            let info = (nuon-info $x)
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
        let f = (catch-fields $e)
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
        let f = (catch-fields $e)
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
                        let got = (norm-type $v)
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
        let f = (catch-fields $e)
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
                    let t = (norm-type $v)
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
        let f = (catch-fields $e)
        {path: $path, n: 0, len_min: null, len_max: null, len_avg: null, len_p95: null, error: $f.error, trace: $f.trace}
    }
}

# Where the mass is, over one column. `{key, n}`, sorted n desc then key asc. Missing column → `[]`.
export def spine [
    column: string                          # Column to group
    --top: int                              # Keep the first N rows after sort
]: any -> any {
    try {
        let x = $in
        let keys = (cols-of $x)
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
        let f = (catch-fields $e)
        {ok: false, error: $f.error, trace: $f.trace}
    }
}

# One bounded slice plus a truthful header. `page` is 1-based; `--at` is a 0-based offset; `--around K -C k` is a window of `2k+1` centered on K (1-based, the peek idiom).
export def page [
    n?: int                                 # 1-based page (default 1 unless --at/--around)
    --size: int = 50                        # Page size
    --at: int                               # 0-based offset; overrides n
    --around: int                           # 1-based center (peek idiom)
    -C: int = 0                             # Half-window for --around
]: any -> record {
    try {
        let x = $in
        let t = (norm-type $x)
        let packed = (
            if $t in ["list" "table"] {
                {kind: "rows", seq: $x, total: (try { $x | length } catch { 0 })}
            } else if $t == "string" {
                let ls = ($x | lines)
                {kind: "lines", seq: $ls, total: ($ls | length)}
            } else {
                let s = (try { $x | to nuon --raw } catch { "" })
                let cs = ($s | split chars)
                {kind: "chars", seq: $cs, total: ($cs | length)}
            }
        )
        let total = $packed.total
        let size = (if $size < 1 { 1 } else { $size })
        mut start = 0
        mut want = $size
        mut page = 1
        mut pages = (if $total == 0 { 0 } else { (($total / $size) | math ceil | into int) })
        if $around != null {
            let center = $around - 1
            let lo = (if ($center - $C) < 0 { 0 } else { $center - $C })
            mut hi = $center + $C + 1
            if $hi > $total { $hi = $total }
            $start = $lo
            $want = $hi - $lo
            $page = 1
            $pages = 1
        } else if $at != null {
            $start = (if $at < 0 { 0 } else { $at })
            $page = (($start / $size) | math floor | into int) + 1
        } else {
            let pg = (if $n == null or $n < 1 { 1 } else { $n })
            $page = $pg
            $start = ($pg - 1) * $size
        }
        let items = (
            if $start >= $total or $want <= 0 {
                if $packed.kind == "chars" { "" } else { [] }
            } else if $packed.kind == "lines" {
                $packed.seq | enumerate | skip $start | first $want
            } else if $packed.kind == "chars" {
                $packed.seq | skip $start | first $want | str join
            } else {
                $packed.seq | skip $start | first $want
            }
        )
        let got = (
            if $packed.kind == "chars" {
                try { $items | str length } catch { 0 }
            } else {
                try { $items | length } catch { 0 }
            }
        )
        {
            kind: $packed.kind
            total: $total
            size: $size
            page: $page
            pages: $pages
            at: $start
            n: $got
            items: $items
        }
    } catch {|e|
        let f = (catch-fields $e)
        {kind: "rows", total: 0, size: 50, page: 1, pages: 0, at: 0, n: 0, items: [], error: $f.error, trace: $f.trace}
    }
}

# The whole structure, leaves clipped. Strings over `--chars` get `… [+N chars]`; lists over `--items` get `[+K more]`. Records keep every key. Idempotent.
export def preview [
    --chars: int = 200                      # String budget
    --items: int = 5                        # List/table budget
    --mode: string = "sandwich"             # head | tail | sandwich
]: any -> any {
    try {
        let mode = (if $mode in ["head" "tail" "sandwich"] { $mode } else { "sandwich" })
        preview-impl $in $chars $items $mode
    } catch {|e|
        let f = (catch-fields $e)
        {ok: false, error: $f.error, trace: $f.trace}
    }
}

# Disclose the body. Under cap → the value. Over cap → stash via `jobs stash` and a receipt naming `jobs read <tag>`. `--env`. The only verb that may decline.
export def --env read []: any -> any {
    try {
        let x = $in
        let info = (nuon-info $x)
        let cap = (resolve-inline-cap)
        let bytes = $info.bytes
        if $bytes == null or $bytes <= $cap {
            return $x
        }
        let known = (
            try { not (scope commands | where name == "jobs stash" | is-empty) } catch { false }
        )
        if not $known {
            return (stamp-meta {
                ok: false
                disclosed: false
                error: "jobs: load jobs first (`use jobs *`)"
                trace: "jobs: load jobs first (`use jobs *`)"
            } "read")
        }
        let stashed = (try { $x | jobs stash } catch {|e|
            let f = (catch-fields $e)
            {ok: false, error: $f.error, trace: $f.trace}
        })
        if ($stashed.ok? == false) {
            return (stamp-meta {
                ok: false
                disclosed: false
                tag: ($stashed.tag? | default null)
                bytes: $bytes
                error: ($stashed.error? | default "stash failed")
                trace: ($stashed.trace? | default ($stashed.error? | default "stash failed"))
            } "read")
        }
        let tag = $stashed.tag
        stamp-meta {
            ok: true
            disclosed: false
            tag: $tag
            bytes: $bytes
            retrieve: $"jobs read ($tag)"
        } "read"
    } catch {|e|
        let f = (catch-fields $e)
        stamp-meta {ok: false, disclosed: false, error: $f.error, trace: $f.trace} "read"
    }
}

# Provenance on a record: `{verb, at, tag?, elapsed?, ref?}`, or `null` when unstamped. Not nushell's `metadata` builtin.
export def meta []: any -> any {
    try {
        let x = $in
        if (norm-type $x) != "record" { return null }
        let m = (try { $x | get -o meta } catch { null })
        if $m == null { return null }
        if (norm-type $m) != "record" { return null }
        if "verb" not-in (cols-of $m) { return null }
        mut out = {verb: $m.verb, at: ($m.at? | default null)}
        if ("tag" in (cols-of $m)) { $out = $out | insert tag $m.tag }
        if ("elapsed" in (cols-of $m)) { $out = $out | insert elapsed $m.elapsed }
        if ("ref" in (cols-of $m)) { $out = $out | insert ref $m.ref }
        $out
    } catch {|e|
        null
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
        let f = (catch-fields $e)
        {ok: false, error: $f.error, trace: $f.trace}
    }
}
