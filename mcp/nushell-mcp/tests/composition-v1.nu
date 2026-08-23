# Child `nu -n` tests for composition-v1 (outcome cut). Run:
#   nu -n mcp/nushell-mcp/tests/composition-v1.nu

const MODULES_DIR = (path self | path dirname | path dirname | path join modules)
const CLI = (path self | path dirname | path dirname | path join deps cli)
const NU_LIB_DIRS = [$MODULES_DIR]
const JOBS_MBOX = 0x4A4F4253

if ($CLI | path exists) {
    let path = (
        if ($env.PATH | describe) =~ "list" { $env.PATH } else { $env.PATH | split row (char esep) }
    )
    $env.PATH = ($path | prepend $CLI)
}

use par *
use jobs *
use dataspection *
use xq *
use rg *
use core/outcome.nu ["outcome project"]
use core/stream.nu ["stream bytes"]
use core/capture.nu ["process capture"]

def assert-eq [left, right, msg: string] {
    if $left != $right {
        error make {msg: $"($msg): expected ($right | to nuon --raw), got ($left | to nuon --raw)"}
    }
}

def assert-true [cond: bool, msg: string] {
    if not $cond { error make {msg: $msg} }
}

def assert-missing [rec: record, col: string, msg: string] {
    if $col in ($rec | columns) { error make {msg: $msg} }
}

def --env reset-jobs [] {
    try {
        if ($env.JOBS? != null) and (not ($env.JOBS | is-empty)) {
            $env.JOBS | each {|r|
                if $r.status == "running" {
                    try { job kill $r.job_id } catch { }
                }
            }
        }
    } catch { }
    $env.JOBS = []
    try { job flush --tag $JOBS_MBOX } catch { try { job flush } catch { } }
}

def --env t [name: string, fn: closure] {
    reset-jobs
    try {
        do $fn
        {name: $name, ok: true, error: null}
    } catch {|e|
        {name: $name, ok: false, error: ($e.msg | lines | first | default $e.msg)}
    }
}

$env.NU_PAR = ($env.NU_PAR | upsert max_workers null | upsert policy "auto")
$env.NU_PAR = (
    $env.NU_PAR
    | upsert ceiling (
        par budget 1 --cores $env.NU_PAR.cores --reserved-cores $env.NU_PAR.reserved_cores | get ceiling
    )
)

let results = [
    (t "outcome record success" {
        let p = ({ok: true, x: 1} | outcome project)
        assert-eq $p.declared true "declared"
        assert-eq $p.ok true "ok"
        assert-eq $p.error null "no error"
    })
    (t "outcome record failure" {
        let p = ({ok: false, error: "boom", tag: "t", retrieve: "jobs fetch t"} | outcome project)
        assert-eq $p.declared true "declared"
        assert-eq $p.ok false "ok"
        assert-eq $p.error "boom" "error"
    })
    (t "outcome record failure fallback" {
        let p = ({ok: false} | outcome project)
        assert-eq $p.declared true "declared"
        assert-eq $p.ok false "ok"
        assert-eq $p.error "failed" "fallback"
    })
    (t "outcome mixed table" {
        let tab = [[ok error]; [true null] [false "no"]]
        let p = ($tab | outcome project)
        assert-eq $p.declared true "declared"
        assert-eq $p.ok false "ok"
        assert-eq $p.error "1 of 2 failed" "aggregate"
    })
    (t "outcome list of records" {
        let lst = [{ok: true, a: 1} {ok: false, error: "no", b: 2}]
        let p = ($lst | outcome project)
        assert-eq $p.declared true "declared"
        assert-eq $p.ok false "ok"
        assert-eq $p.error "1 of 2 failed" "list aggregate"
    })
    (t "outcome empty table" {
        let p = ([] | outcome project)
        assert-eq $p.declared false "not declared"
        assert-eq $p.ok true "ok"
        assert-eq $p.error null "no error"
    })
    (t "outcome ordinary list" {
        let p = ([1 2 3] | outcome project)
        assert-eq $p.declared false "not declared"
        assert-eq $p.ok true "ok"
    })
    (t "outcome mixed list is not an outcome" {
        let p = ([{ok: false, error: "x"} 1] | outcome project)
        assert-eq $p.declared false "not declared"
        assert-eq $p.ok true "ordinary success"
    })
    (t "outcome nested ok ignored" {
        let p = ({value: {ok: false, error: "no"}, n: 1} | outcome project)
        assert-eq $p.declared false "not declared"
        assert-eq $p.ok true "not lifted"
    })
    (t "par throw still fail-soft" {
        let rows = ([3 1 2] | par {|x| if $x == 1 { error make {msg: "x"} } else { $x } })
        assert-eq ($rows | length) 3 "three rows"
        assert-eq ($rows | get ok) [true false true] "mixed"
        assert-eq ($rows | get value) [3 null 2] "thrown value null"
        assert-true (($rows | get 1.error) != null) "error present"
    })
    (t "par returned failure retains value" {
        let fail = {ok: false, error: "x", tag: "t", retrieve: "jobs fetch t", meta: {verb: "xq"}}
        let rows = ([1 2] | par {|i| if $i == 1 { $fail } else { $i } })
        assert-eq ($rows | length) 2 "two rows"
        assert-eq ($rows | get ok) [false true] "lifted"
        assert-eq ($rows | get 0.value) $fail "original retained"
        assert-eq ($rows | get 0.value.tag) "t" "tag kept"
        assert-eq ($rows | get 0.value.retrieve) "jobs fetch t" "retrieve kept"
        assert-eq ($rows | get 0.value.meta.verb) "xq" "meta kept"
        assert-eq ($rows | get 0.error) "x" "lifted error"
        assert-eq ($rows | get 1.value) 2 "sibling value"
        assert-eq ($rows | get 1.ok) true "sibling ok"
    })
    (t "par returned outcome table retained" {
        let inner = [[ok error]; [true null] [false "no"]]
        let rows = ([0] | par {|_| $inner })
        assert-eq ($rows | length) 1 "one row"
        assert-eq ($rows | get 0.ok) false "lifted aggregate"
        assert-eq ($rows | get 0.value) $inner "table retained"
        assert-eq ($rows | get 0.error) "1 of 2 failed" "aggregate error"
    })
    (t "par ordinary value" {
        let rows = ([4] | par {|x| $x * 2 })
        assert-eq ($rows | get 0.ok) true "ok"
        assert-eq ($rows | get 0.value) 8 "value"
        assert-eq ($rows | get 0.error) null "no error"
    })
    (t "jobs spawn returned domain failure" {
        let fail = {ok: false, error: "x", tag: "t", retrieve: "jobs fetch t"}
        let _ = (jobs spawn { $fail } --tag dom)
        let c = (jobs collect --timeout 3sec)
        assert-eq ($c | length) 1 "one"
        assert-eq ($c | get 0.status) "completed" "completed"
        assert-eq ($c | get 0.ok) false "ok false"
        assert-true ("output" not-in ($c | columns)) "no body on collect"
        let body = (jobs fetch dom)
        assert-eq $body $fail "payload including tag/retrieve"
        assert-eq $body.tag "t" "tag"
        assert-eq $body.retrieve "jobs fetch t" "retrieve"
    })
    (t "jobs spawn mixed par fetchable" {
        let _ = (jobs spawn {
            [true false] | par {|x| if $x { 1 } else { {ok: false, error: "no"} } }
        } --tag mix)
        let c = (jobs collect --timeout 3sec)
        assert-eq ($c | get 0.status) "completed" "completed"
        assert-eq ($c | get 0.ok) false "aggregate false"
        let table = (jobs fetch mix)
        assert-eq ($table | length) 2 "both rows"
        assert-eq ($table | get ok) [true false] "mixed rows"
        assert-eq ($table | get 1.value.error) "no" "inner error kept"
    })
    (t "jobs spawn throw is failed no payload" {
        let _ = (jobs spawn { error make {msg: "boom"} } --tag thr)
        let c = (jobs collect --timeout 3sec)
        assert-eq ($c | get 0.status) "failed" "failed"
        assert-eq ($c | get 0.ok) false "ok"
        let bad = (jobs fetch thr)
        assert-eq $bad.ok false "fetch is data"
        assert-eq $bad.status "failed" "status"
        assert-eq $bad.disclosed false "not disclosed"
    })
    (t "jobs spawn xq missing is completed domain failure" {
        let _ = (jobs spawn { xq definitely-not-a-cmd-xyz } --tag xm)
        let c = (jobs collect --timeout 3sec)
        assert-eq ($c | get 0.status) "completed" "completed"
        assert-eq ($c | get 0.ok) false "ok false"
        let body = (jobs fetch xm)
        assert-eq $body.ok false "xq ok"
        assert-eq $body.exit_code null "exit null"
        assert-true (($body.error | default "") | str starts-with "not found:") "not found"
    })
    (t "jobs cancel missing and non-running" {
        let miss = (jobs cancel 999999)
        assert-eq $miss.ok false "missing ok"
        assert-eq $miss.cancelled false "missing cancelled"
        assert-eq $miss.job_id 999999 "id"
        assert-true (($miss.error | default "") != "") "error"
        let a = (jobs spawn { 1 } --tag done)
        let _ = (jobs collect --timeout 3sec)
        let k = (jobs cancel $a.job_id)
        assert-eq $k.ok false "completed cancel ok"
        assert-eq $k.cancelled false "not cancelled"
        assert-eq $k.error "completed" "status as error"
    })
    (t "jobs cancel success has ok true" {
        let a = (jobs spawn { sleep 5sec; 1 } --tag live)
        let k = (jobs cancel $a.job_id)
        assert-eq $k.ok true "ok"
        assert-eq $k.cancelled true "cancelled"
        assert-eq $k.job_id $a.job_id "id"
    })
    (t "jobs stash does not project payload" {
        let r = ({ok: false, error: "x"} | jobs stash --tag sfail)
        assert-eq $r.ok true "storage ok"
        assert-eq $r.status "completed" "completed-on-arrival"
        assert-eq (jobs fetch sfail) {ok: false, error: "x"} "payload intact"
    })
    (t "prefix skips pre-seeded tags" {
        let _ = ("seed" | jobs stash --tag "rg:0")
        let r = ("payload" | jobs stash --prefix "rg")
        assert-eq $r.ok true "stash ok"
        assert-eq $r.tag "rg:1" "skipped 0"
        assert-eq (jobs fetch "rg:0") "seed" "seed intact"
        assert-eq (jobs fetch "rg:1") "payload" "new payload"
    })
    (t "prefix fills holes" {
        let _ = ("hole" | jobs stash --tag "rg:2")
        let r = ("p" | jobs stash --prefix "rg")
        assert-eq $r.tag "rg:0" "smallest free"
        assert-eq (jobs fetch "rg:2") "hole" "hole intact"
        assert-eq (jobs fetch "rg:0") "p" "allocated 0"
    })
    (t "tag and prefix mutually exclusive" {
        let r = ("x" | jobs stash --tag t --prefix "stash")
        assert-eq $r.ok false "ok"
        assert-true (($r.error | default "") | str contains "exclusive") "error"
        assert-eq (jobs list | length) 0 "nothing stored"
    })
    (t "foreground par xq over cap no phantom tag" {
        let exe = $nu.current-exe
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 50)
        let rows = ([1 2] | par {|_| xq $exe -n -c "1..2000 | to text" })
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        assert-eq ($rows | length) 2 "both rows"
        assert-eq ($rows | get ok) [false false] "lifted"
        assert-eq ($rows | get 0.value.ok) false "xq ok"
        assert-eq ($rows | get 0.value.truncated) false "not truncated"
        assert-true ("tag" not-in ($rows | get 0.value | columns)) "no tag"
        assert-true ("stdout" not-in ($rows | get 0.value | columns)) "no dump"
        assert-eq (jobs list | length) 0 "no phantom stash"
    })
    (t "jobs spawn par xq over cap one row" {
        let exe = $nu.current-exe
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 50)
        let _ = (jobs spawn {
            [1 2] | par {|_| xq $exe -n -c "1..2000 | to text" }
        } --tag bg)
        let _ = (jobs collect --timeout 5sec)
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        assert-eq (jobs list | length) 1 "exactly one row"
        assert-eq (jobs list | get 0.tag) "bg" "job tag"
        let table = (jobs fetch bg)
        assert-eq ($table | length) 2 "both children"
        assert-true (($table | get 0.value.stdout | str length) > 50) "full stdout"
        assert-true ("tag" not-in ($table | get 0.value | columns)) "no nested tag"
    })
    (t "jobs emit inside job no nested stash" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 50)
        let _ = (jobs spawn {
            1..40 | par {|i| $i } | jobs emit
        } --tag bg)
        let _ = (jobs collect --timeout 5sec)
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        assert-eq (jobs list | length) 1 "one row"
        let envl = (jobs fetch bg)
        assert-eq $envl.truncated false "not truncated"
        assert-true ("findings" in ($envl | columns)) "findings inline"
        assert-true ("tag" not-in ($envl | columns)) "no emit tag"
    })
    (t "stream bytes string binary record" {
        let s = ("hello" | stream bytes)
        assert-eq $s.ok true "string ok"
        assert-eq $s.bytes 5 "utf8"
        let b = (0x[00 ff 80] | stream bytes)
        assert-eq $b.ok true "binary ok"
        assert-eq $b.bytes 3 "binary len"
        let r = ({a: 1} | stream bytes)
        assert-eq $r.ok false "record fails"
        assert-eq $r.bytes null "no zero fallback"
    })
    (t "capture success ok independent of exit" {
        let exe = $nu.current-exe
        let c = (process capture $exe -n -c "exit 2")
        assert-eq $c.ok true "capture ran"
        assert-eq $c.exit_code 2 "child exit"
        assert-eq $c.cmd $exe "cmd"
        assert-eq $c.args [-n -c "exit 2"] "args"
        let miss = (process capture definitely-not-a-cmd-xyz --flag)
        assert-eq $miss.ok false "miss"
        assert-eq $miss.args [--flag] "args preserved"
        assert-true (($miss.error | default "") | str starts-with "not found:") "normalized"
    })
    (t "binary stdout over cap stashed byte-for-byte" {
        let exe = $nu.current-exe
        let dir = ($nu.temp-dir | path join $"comp-bin-($nu.pid)")
        mkdir $dir
        mut acc = 0x[]
        for _ in 1..200 { $acc = ($acc ++ 0x[ff]) }
        let f = ($dir | path join "big.bin")
        $acc | save --raw $f
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 20)
        let r = (xq $exe -n -c $"open --raw ($f | to nuon --raw)")
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        assert-eq $r.truncated true "truncated"
        assert-true ("stdout" not-in ($r | columns)) "no inline"
        assert-true ($r.tag != null) "tag"
        let body = (jobs fetch $r.tag)
        assert-eq $body.stdout $acc "byte-for-byte"
        try { rm -r $dir } catch { }
    })
    (t "rg byte-backed line is unsupported encoding" {
        if (which rg | is-empty) {
            error make {msg: "rg not on PATH"}
        }
        let dir = ($nu.temp-dir | path join $"comp-rg-($nu.pid)")
        mkdir $dir
        let f = ($dir | path join "a.txt")
        0x[6e 65 65 64 6c 65 ff 0a] | save --raw $f
        let r = (rg needle $f)
        try { rm -r $dir } catch { }
        assert-eq $r.ok false "ok"
        assert-true (($r.error | default "") | str contains "encoding") "encoding"
        assert-true ("findings" not-in ($r | columns)) "no findings"
        assert-true ("match" not-in ($r | columns)) "no match field"
    })
    (t "worker stash spawn cancel fail as data" {
        let rows = ([1] | par {|_| "x" | jobs stash --tag w })
        assert-eq ($rows | get 0.ok) false "stash lifted"
        assert-eq ($rows | get 0.value.ok) false "stash ok"
        assert-eq ($rows | get 0.value.error) "not registry owner" "stash error"
        assert-eq (jobs list | length) 0 "no row"
        let sp = ([1] | par {|_| jobs spawn { 1 } --tag inner })
        assert-eq ($sp | get 0.value.ok) false "spawn ok"
        assert-eq ($sp | get 0.value.error) "not registry owner" "spawn error"
        let k = ([1] | par {|_| jobs cancel 1 })
        assert-eq ($k | get 0.value.ok) false "cancel ok"
        assert-eq ($k | get 0.value.cancelled) false "not cancelled"
        assert-eq ($k | get 0.value.error) "not registry owner" "cancel error"
    })
]

reset-jobs

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
    error make {msg: $"($failed | length) tests failed: ($failed | get name | str join ', ')"}
}
