# Child `nu -n` tests for composition-v1 (outcome cut). Run:
#   nu -n mcp/nushell-mcp/tests/composition-v1.nu

const MODULES_DIR = (path self | path dirname | path dirname | path join modules)
const NU_LIB_DIRS = [$MODULES_DIR]
const JOBS_MBOX = 0x4A4F4253

use par *
use jobs *
use dataspection *
use xq *
use core/outcome.nu ["outcome project"]

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
