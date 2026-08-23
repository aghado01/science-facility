# views — bounded disclosure: preview (clipped leaves) and page (one slice).

use ./failure.nu ["failure fields"]
use ./value.nu ["value kind" "value columns"]

def already-clipped-str [s: string]: nothing -> bool {
    ($s | str contains "… [+")
}

def already-clipped-list [xs]: nothing -> bool {
    let n = (try { $xs | length } catch { 0 })
    if $n == 0 { return false }
    let last = (try { $xs | last } catch { null })
    if ($last | value kind) != "string" { return false }
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
    let t = ($x | value kind)
    if $t == "string" {
        clip-str $x $chars $mode
    } else if $t == "record" {
        $x | value columns | reduce --fold {} {|k, acc|
            $acc | insert $k (preview-impl (try { $x | get $k } catch { null }) $chars $items $mode)
        }
    } else if $t in ["list" "table"] {
        let xs = (try { $x | each {|el| preview-impl $el $chars $items $mode} } catch { [] })
        clip-list $xs $items $mode
    } else {
        $x
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
        let t = ($x | value kind)
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
        let f = (failure fields $e)
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
        let f = (failure fields $e)
        {ok: false, error: $f.error, trace: $f.trace}
    }
}
