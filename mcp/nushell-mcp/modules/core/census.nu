# census — shape / shape each. What par and jobs consume.
# `bytes` is NUON UTF-8 length via `value nuon`. Always fits.

use ./failure.nu ["failure fields"]
use ./value.nu ["value kind" "value columns" "value nuon"]

def head-of [s: string]: nothing -> string {
    let one = ($s | str replace --all "\n" " " | str replace --all "\r" " ")
    if ($one | str length) <= 80 { $one } else { $one | str substring ..<80 }
}

def shape-core [x]: nothing -> record {
    let t = ($x | value kind)
    let info = ($x | value nuon)
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
            $x | value columns | each {|n|
                let vt = (if $row0 == null { "nothing" } else { (try { $row0 | get $n } catch { null }) | value kind })
                {name: $n, type: $vt}
            }
        )
        mut nulls = 0
        for col in ($x | value columns) {
            let cells = (try { $x | get $col } catch { [] })
            for v in $cells {
                if ($v | value kind) == "nothing" { $nulls = $nulls + 1 }
            }
        }
        $rec = ($rec | insert columns $columns | insert nulls $nulls)
    } else if $t == "record" {
        let columns = (
            $x | value columns | each {|n|
                {name: $n, type: ((try { $x | get $n } catch { null }) | value kind)}
            }
        )
        $rec = ($rec | insert columns $columns)
        if "ok" in ($x | value columns) {
            $rec = ($rec | insert ok (try { $x | get ok } catch { null }))
        }
    }
    if $info.ok == false {
        $rec = ($rec | upsert ok false | insert error $info.error | insert trace $info.trace)
    }
    $rec
}

def shape-each-row [index: int, item] {
    let s = (shape-core $item)
    let isrec = ($item | value kind) == "record"
    let keys = (if $isrec { $item | value columns } else { [] })
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
    if ("error" in ($s | value columns)) {
        $row = ($row | insert error $s.error | insert trace $s.trace)
    }
    $row
}

def fail-shape [e]: nothing -> record {
    let f = (failure fields $e)
    {ok: false, type: "other", length: null, bytes: null, head: "", error: $f.error, trace: $f.trace}
}

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
        let t = ($x | value kind)
        if $t in ["list" "table"] {
            let n = (try { $x | length } catch { 0 })
            if $n == 0 { return [] }
            $x | enumerate | each {|it| shape-each-row $it.index $it.item }
        } else {
            [ (shape-each-row 0 $x) ]
        }
    } catch {|e|
        let f = (failure fields $e)
        {ok: false, error: $f.error, trace: $f.trace}
    }
}
