# Child `nu -n` tests for dataspection v1. Run:
#   nu -n mcp/nushell-mcp/tests/dataspection-v1.nu

const MODULES_DIR = (path self | path dirname | path dirname | path join modules)
const NU_LIB_DIRS = [$MODULES_DIR]

use par *
use jobs *
use dataspection *

def assert-eq [left, right, msg: string] {
    if $left != $right {
        error make {msg: $"($msg): expected ($right | to nuon --raw), got ($left | to nuon --raw)"}
    }
}

def assert-true [cond: bool, msg: string] {
    if not $cond { error make {msg: $msg} }
}

def assert-has [rec: record, col: string, msg: string] {
    if not ($col in ($rec | columns)) { error make {msg: $msg} }
}

def assert-missing [rec: record, col: string, msg: string] {
    if $col in ($rec | columns) { error make {msg: $msg} }
}

def long-str [n: int] {
    1..$n | each { "xxxx" } | str join
}

def --env t [name: string, fn: closure] {
    try {
        do $fn
        {name: $name, ok: true, error: null}
    } catch {|e|
        {name: $name, ok: false, error: ($e.msg | lines | first | default $e.msg)}
    }
}

let results = [
    (t "shape table" {
        let x = [[a b]; [1 null] [2 3]]
        let s = ($x | shape)
        assert-eq $s.type "table" "type"
        assert-eq $s.length 2 "length"
        assert-true ($s.bytes > 0) "bytes"
        assert-true (($s.head | str length) <= 80) "head <= 80"
        assert-eq ($s.head | str contains "\n") false "head one line"
        assert-eq ($s.columns | get name) [a b] "column names"
        assert-eq ($s.columns | get type) [int nothing] "column types from row 0"
        assert-eq $s.nulls 1 "one null cell"
        assert-missing $s "error" "no error"
        assert-missing $s "trace" "no trace"
        let raw = ($x | to nuon --raw | str length --utf-8-bytes)
        assert-eq $s.bytes $raw "bytes == nuon utf-8"
    })
    (t "shape scalars" {
        assert-eq ("ab" | shape | get type) "string" "string"
        assert-eq ("ab" | shape | get length) 2 "string length utf-8"
        assert-eq (7 | shape | get type) "int" "int"
        assert-eq (7 | shape | get length) null "int length null"
        assert-eq ({a: 1} | shape | get type) "record" "record"
        assert-eq ({a: 1} | shape | get columns | get name) [a] "record columns"
        assert-eq ([] | shape | get type) "list" "empty list"
        assert-eq ([] | shape | get length) 0 "empty length"
        assert-eq (null | shape | get type) "nothing" "null"
        assert-eq (null | shape | get length) null "null length"
        let c = ({|x| $x} | shape)
        assert-eq $c.type "closure" "closure"
        assert-eq $c.bytes null "closure bytes null"
        assert-has $c "error" "closure error"
        assert-has $c "trace" "closure trace"
        assert-true (($c.trace | str length) > 0) "trace nonempty"
    })
    (t "shape each" {
        let rows = ([1 "ab" [1 2 3] {a: 1}] | shape each)
        assert-eq ($rows | length) 4 "4 rows"
        assert-eq ($rows | get index) [0 1 2 3] "index"
        assert-eq ($rows | get type) ["int" "string" "list" "record"] "types"
        assert-true ("columns" not-in ($rows | columns)) "no columns"
        assert-eq ([] | shape each) [] "empty"
        let lifted = ([
            {ok: false, meta: {verb: "xq", at: 2020-01-01}}
            {ok: true, meta: {verb: "rg", at: 2020-01-01}}
        ] | shape each)
        assert-eq ($lifted | get ok) [false true] "ok lifted"
        assert-eq ($lifted | get verb) ["xq" "rg"] "verb lifted"
    })
    (t "schema heterogeneous" {
        let s = ([
            {name: "a" age: 1 extra: "x"}
            {name: "b" age: 2}
        ] | schema)
        let paths = ($s | get path)
        assert-eq $paths ($paths | sort) "lexical"
        assert-true ("name" in $paths) "name"
        assert-true ("age" in $paths) "age"
        assert-true ("extra" in $paths) "extra"
        let extra = ($s | where path == "extra" | get 0)
        assert-true ($extra.coverage < 100) "sparse extra"
        assert-true ($extra.hits >= 1) "hits"
        assert-true ($extra.records >= 1) "records"
        assert-eq ($s | where path == "name" | get 0.coverage) 100 "name full"
        let rec = ({a: 1, b: {c: true}, items: [{id: 1}]} | schema)
        assert-eq ($rec | where path == "a" | get 0.coverage) 100 "record pop 1"
        assert-true ("items[].id" in ($rec | get path)) "list path"
        assert-true ("b.c" in ($rec | get path)) "nested"
    })
    (t "schema diff check stats" {
        let a = ([{a: 1}] | schema)
        let b = ([{a: "x", z: true}] | schema)
        let d = ($a | schema diff $b)
        assert-true (("added" in ($d | get status)) or ("changed" in ($d | get status))) "has added or changed"
        assert-eq ($d | where path == "z" | get 0.status) "added" "z added"
        assert-eq ($d | where path == "a" | get 0.status) "changed" "a changed"
        assert-eq ($d | where path == "a" | get 0.before) "int" "before"
        assert-eq ($d | where path == "a" | get 0.after) "string" "after"
        let chk = ([{a: "no"}] | schema check $a)
        assert-eq $chk.ok false "check fails"
        assert-true (($chk.violations | length) > 0) "violations"
        assert-eq ($chk.violations | get 0.path) "a" "path"
        assert-eq ($chk.violations | get 0.got) "string" "got"
        let okc = ([{a: 1}] | schema check $a)
        assert-eq $okc.ok true "check ok"
        let st = ([{body: {text: "hello"}}, {body: {text: "hi"}}] | schema stats "body.text")
        assert-eq $st.path "body.text" "stats path"
        assert-eq $st.n 2 "n"
        assert-eq $st.len_min 2 "min"
        assert-eq $st.len_max 5 "max"
        let miss = ([{a: 1}] | schema stats "nope")
        assert-eq $miss.n 0 "missing n"
    })
    (t "spine" {
        let t = [[file]; [a] [b] [a] [c] [a]]
        let s = ($t | spine file)
        assert-eq ($s | get key) [a b c] "n desc then key asc"
        assert-eq ($s | get n) [3 1 1] "counts"
        assert-eq ($t | spine file --top 1 | get key) [a] "top"
        assert-eq ($t | spine nope) [] "missing column"
    })
    (t "page" {
        let xs = [1 2 3 4 5 6 7 8 9 10]
        let p = ($xs | page 2 --size 3)
        assert-eq $p.kind "rows" "kind"
        assert-eq $p.total 10 "total"
        assert-eq $p.size 3 "size"
        assert-eq $p.page 2 "page"
        assert-eq $p.pages 4 "pages"
        assert-eq $p.at 3 "at"
        assert-eq $p.n 3 "n"
        assert-eq $p.items [4 5 6] "items"
        let oob = ($xs | page 99 --size 10)
        assert-eq $oob.items [] "oob empty"
        assert-eq $oob.total 10 "oob total"
        assert-eq $oob.page 99 "oob page"
        let s = ("a\nb\nc\nd\ne" | page --around 3 -C 1)
        assert-eq $s.kind "lines" "lines"
        assert-eq ($s.items | get item) [b c d] "around items"
        assert-eq ($s.items | get index) [1 2 3] "line numbers via enumerate"
        let shuf = ([3 1 2] | page 1 --size 3)
        assert-eq $shuf.items [3 1 2] "never reorders"
        let ch = (7 | page 1 --size 10)
        assert-eq $ch.kind "chars" "scalar chars"
    })
    (t "preview" {
        let s = (long-str 80)
        let h = ($s | preview --chars 10 --mode head)
        assert-true ($h | str contains "… [+") "head marker"
        assert-true ($h | str starts-with ($s | str substring ..<10)) "head prefix"
        let tmode = ($s | preview --chars 10 --mode tail)
        assert-true ($tmode | str contains "… [+") "tail marker"
        let sw = ($s | preview --chars 10 --mode sandwich)
        assert-true ($sw | str contains "… [+") "sandwich marker"
        let xs = [1 2 3 4 5 6 7 8]
        let pl = ($xs | preview --items 3 --mode head)
        assert-eq ($pl | last) "[+5 more]" "list marker"
        assert-eq ($pl | first 3) [1 2 3] "list head"
        let rec = ({a: ("n" | str join), b: 1, text: (long-str 80)} | preview --chars 10)
        assert-true ("a" in ($rec | columns)) "keeps keys"
        assert-true ("b" in ($rec | columns)) "keeps b"
        assert-true ("text" in ($rec | columns)) "keeps text"
        let once = ($s | preview --chars 10 --mode head)
        let twice = ($once | preview --chars 10 --mode head)
        assert-eq $once $twice "idempotent"
    })
    (t "meta stamp" {
        let r = ({a: 1} | meta stamp --verb xq --tag t)
        assert-eq $r.a 1 "keeps fields"
        assert-eq $r.meta.verb "xq" "verb"
        assert-true ($r.meta.at != null) "at"
        assert-eq $r.meta.tag "t" "tag"
        assert-true ("elapsed" not-in ($r.meta | columns)) "elapsed absent"
        assert-true ("ref" not-in ($r.meta | columns)) "ref absent"
        let wrapped = (7 | meta stamp --verb xq)
        assert-eq $wrapped.value 7 "wraps non-record"
        assert-eq $wrapped.meta.verb "xq" "wrap verb"
        let tab = ([[a]; [1] [2]] | meta stamp --verb xq)
        assert-true ("value" in ($tab | columns)) "table wrapped"
        assert-eq ($tab.value | length) 2 "table not per-row"
        let twice = ($r | meta stamp --verb other)
        assert-eq $twice.meta.verb "other" "replace"
        assert-eq ($twice.meta.meta? | default null) null "no nest"
        assert-eq ({a: 1} | meta) null "unstamped"
        assert-eq ($r | meta | get verb) "xq" "meta projects"
        assert-eq (7 | meta) null "meta on non-record"
    })
    (t "read under and over cap" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 100000)
        assert-eq ([1 2 3] | read) [1 2 3] "under cap"
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 20)
        let v = (long-str 20)
        let r = ($v | read)
        assert-eq $r.ok true "decline ok"
        assert-eq $r.disclosed false "not disclosed"
        assert-true ($r.tag != null) "tag"
        assert-true ($r.bytes > 20) "bytes over cap"
        assert-eq $r.retrieve $"jobs read ($r.tag) --full" "retrieve"
        assert-eq $r.meta.verb "read" "stamped"
        assert-eq (jobs read $r.tag --full) $v "retrievable"
        assert-eq $v (long-str 20) "peek not pop"
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
    })
    (t "read jobs missing" {
        let exe = $nu.current-exe
        let snippet = [
            $"const NU_LIB_DIRS = [($MODULES_DIR | to nuon)]"
            "use dataspection *"
            "$env.NU_PAR = {max_inline_bytes: 10}"
            "let s = (1..30 | each { 'xxxx' } | str join)"
            "$s | read | to nuon --raw"
        ] | str join (char nl)
        let out = (^$exe -n -c $snippet | complete)
        assert-eq $out.exit_code 0 "child ok"
        let val = ($out.stdout | str trim | from nuon)
        assert-eq $val.ok false "ok false"
        assert-eq $val.disclosed false "not disclosed"
        assert-true ($val.error | str contains "jobs") "error names jobs"
        assert-true (($val.trace | str length) > 0) "trace"
    })
    (t "null and empty string" {
        assert-eq (null | shape | get type) "nothing" "shape null"
        assert-eq ("" | shape | get type) "string" "shape empty"
        assert-eq (null | schema) [] "schema null"
        assert-eq ("" | schema) [] "schema empty"
        assert-eq (null | spine x) [] "spine null"
        assert-eq ("" | spine x) [] "spine empty"
        assert-eq (null | page 1 | get kind) "chars" "page null"
        assert-eq ("" | page 1 | get kind) "lines" "page empty"
        assert-eq (null | preview) null "preview null"
        assert-eq ("" | preview) "" "preview empty"
        assert-eq (null | meta) null "meta null"
        assert-eq ("" | meta) null "meta empty"
        let stn = (null | meta stamp --verb xq)
        assert-eq $stn.value null "stamp null wraps"
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 100000)
        assert-eq (null | read) null "read null"
        assert-eq ("" | read) "" "read empty"
    })
    (t "forced internal failure" {
        let s = ({|x| $x} | schema)
        assert-has $s "error" "schema error"
        assert-has $s "trace" "schema trace"
        assert-true (($s.trace | str length) > 0) "trace nonempty"
        let sh = ({|x| $x} | shape)
        assert-has $sh "error" "shape error"
        assert-has $sh "trace" "shape trace"
        assert-missing ({a: 1} | shape) "error" "success no error"
        assert-missing ({a: 1} | shape) "trace" "success no trace"
    })
]

let failed = ($results | where ok == false)
let summary = {
    n: ($results | length)
    n_ok: ($results | where ok | length)
    n_err: ($failed | length)
    failed: ($failed | get name? | default [])
}
print -e ($results | select name ok error | to nuon --raw)
print -e ($summary | to nuon --raw)
if ($failed | is-empty) {
    $results | select name ok
} else {
    $results | select name ok error
}
