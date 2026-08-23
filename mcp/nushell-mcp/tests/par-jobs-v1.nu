# Child `nu -n` tests for par / jobs v1. Run:
#   nu -n mcp/nushell-mcp/tests/par-jobs-v1.nu

const MODULES_DIR = (path self | path dirname | path dirname | path join modules)
const NU_LIB_DIRS = [$MODULES_DIR]
const JOBS_MBOX = 0x4A4F4253

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

def wait-gone [id: int, limit: duration = 3sec] {
    let t0 = (date now)
    loop {
        let live = (try { job list | get id } catch { [] })
        if not ($id in ($live | default [])) { return }
        if ((date now) - $t0) > $limit {
            error make {msg: $"job ($id) still in job list"}
        }
        sleep 20ms
    }
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

def jobs-running-safe [] {
    if ($env.JOBS? == null) or ($env.JOBS | is-empty) { 0 } else {
        $env.JOBS | where status == "running" | length
    }
}

def grant-of [items: int, --threads: int] {
    if $threads != null {
        par budget $items --threads $threads --cores 16 --reserved-cores 2 --min-items-per-worker 4 | get grant
    } else {
        par budget $items --cores 16 --reserved-cores 2 --min-items-per-worker 4 | get grant
    }
}

# Isolate auto-policy from any sticky max_workers.
$env.NU_PAR = ($env.NU_PAR | upsert max_workers null | upsert policy "auto")
$env.NU_PAR = (
    $env.NU_PAR
    | upsert ceiling (
        par budget 1 --cores $env.NU_PAR.cores --reserved-cores $env.NU_PAR.reserved_cores | get ceiling
    )
)

let results = [
    (t "budget table" {
        assert-eq (grant-of 1) 1 "items=1"
        assert-eq (grant-of 4) 1 "items=4"
        assert-eq (grant-of 8) 2 "items=8"
        assert-eq (grant-of 20) 5 "items=20"
        assert-eq (grant-of 60) 14 "items=60"
        assert-eq (grant-of 200) 14 "items=200"
    })
    (t "budget clamp explicit 32" {
        let b = (par budget 200 --threads 32 --cores 16 --reserved-cores 2 --min-items-per-worker 4)
        assert-eq $b.ceiling 16 "ceiling clamped to cores"
        assert-eq $b.grant 16 "grant clamped to cores"
        assert-true $b.clamped "clamped flag"
        assert-true ($b.warning != null) "warning present"
    })
    (t "budget explicit 1 items 200" {
        assert-eq (grant-of 200 --threads 1) 1 "explicit 1"
    })
    (t "par fail-soft mixed ok" {
        let rows = ([3 1 2] | par {|x| if $x == 1 { error make {msg: "x"} } else { $x } })
        assert-eq ($rows | length) 3 "three rows"
        assert-eq ($rows | get index) [0 1 2] "index order"
        assert-eq ($rows | get ok) [true false true] "mixed ok"
        assert-eq ($rows | get value) [3 null 2] "later value present"
        assert-true (($rows | get 1.error) != null) "middle error"
    })
    (t "par keep-order with slow first" {
        let rows = ([1 2 3] | par {|x| if $x == 1 { sleep 200ms }; $x })
        assert-eq ($rows | get index) [0 1 2] "index 0 first"
        assert-eq ($rows | get item) [1 2 3] "input order"
        assert-eq ($rows | get value) [1 2 3] "values"
    })
    (t "par empty" {
        assert-eq ([] | par {|x| $x}) [] "empty in, empty out"
    })
    (t "spawn without tag allocates" {
        let a = (jobs spawn { 7 })
        assert-eq $a.status "running" "running"
        assert-true ($a.tag | str starts-with "spawn:") "spawn prefix"
        let b = (jobs spawn { 8 })
        assert-true ($b.tag | str starts-with "spawn:") "second prefix"
        assert-true ($a.tag != $b.tag) "distinct"
        let c = (jobs collect --timeout 3sec)
        assert-eq ($c | length) 2 "both"
        assert-eq (jobs fetch $a.tag) 7 "first payload"
        assert-eq (jobs fetch $b.tag) 8 "second payload"
    })
    (t "two jobs first errors" {
        let a = (jobs spawn { error make {msg: "boom"} } --tag err-a)
        let b = (jobs spawn { 7 } --tag err-b)
        assert-eq $a.status "running" "spawn a"
        assert-eq $b.status "running" "spawn b"
        let c = (jobs collect --timeout 3sec)
        assert-eq ($c | length) 2 "both receipts"
        assert-eq ($c | get tag) [err-a err-b] "seq order"
        assert-eq ($c | get ok) [false true] "mixed ok"
        assert-true ("output" not-in ($c | columns)) "no output column"
        assert-true (($c | get 0.finished) != null) "failure finished"
        assert-true (($c | get 0.elapsed) != null) "failure elapsed"
        assert-true (($c | get 0.error | str length) > 0) "short error"
        assert-true (($c | get 0.error | str length) <= 240) "error short"
        assert-eq (jobs read err-b) 7 "success readable"
        let bad = (jobs read err-a)
        assert-eq $bad.ok false "failed read is data"
        assert-eq $bad.disclosed false "not disclosed"
        assert-eq $bad.status "failed" "status"
        assert-eq (jobs fetch err-a).ok false "failed fetch is data"
        assert-eq (jobs list | where status == "cancelled" | length) 0 "sibling not cancelled"
    })
    (t "collect seq order not completion order" {
        let _ = (jobs spawn { sleep 350ms; "slow" } --tag slow)
        let _ = (jobs spawn { "fast" } --tag fast)
        let c = (jobs collect --timeout 3sec)
        assert-eq ($c | length) 2 "two receipts"
        assert-eq ($c | get tag) [slow fast] "seq order, slow still row 0"
        assert-true ("output" not-in ($c | columns)) "no output column"
        assert-true (($c | get 0.bytes) != null) "bytes present"
        assert-true (($c | get 0.type) != null) "type present"
        assert-eq ($c | get ok) [true true] "both ok"
    })
    (t "read one tag quarantines the other" {
        let _ = (jobs spawn { "alpha" } --tag ra)
        let _ = (jobs spawn { "beta" } --tag rb)
        let _ = (jobs collect --timeout 3sec)
        let v = (jobs read ra)
        assert-eq $v "alpha" "read ra"
        # this evaluate's return is the assertion value, not both payloads
        assert-true ($v != "beta") "other payload not in return"
        assert-eq (jobs read rb) "beta" "rb still stored"
    })
    (t "inspect has no body" {
        let spawned = (jobs spawn { {secret: 99} } --tag insp)
        assert-eq $spawned.meta.verb "jobs.spawn" "spawn stamped"
        let _ = (jobs collect --timeout 3sec)
        let i = (jobs inspect insp)
        assert-true ("output" not-in ($i | columns)) "no output field"
        assert-true ("secret" not-in ($i | columns)) "no payload keys"
        assert-true ("disclosed" not-in ($i | columns)) "inspect is not a decline"
        assert-eq $i.ok true "ok"
        assert-true ($i.bytes != null) "bytes"
        assert-true ($i.type != null) "type"
        assert-eq $i.meta.verb "jobs.inspect" "inspect stamped"
        let s = (jobs read insp | shape)
        assert-eq $i.bytes $s.bytes "bytes from shape"
        assert-eq $i.type $s.type "type from shape"
        assert-eq $i.length $s.length "length from shape"
        assert-eq (jobs read insp) {secret: 99} "body only via read"
    })
    (t "flatten-by-index" {
        let rows = (
            [
                {wait: 200ms, hits: [a b]}
                {wait: 0sec, hits: [c]}
            ]
            | par {|r| sleep $r.wait; $r.hits }
        )
        let flat = ($rows | sort-by index | get value | flatten)
        assert-eq $flat [a b c] "concat by index then in-list, not finish order"
        assert-eq ($rows | get index) [0 1] "par rows in input order"
    })
    (t "query envelope over cap" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 50)
        let rows = (1..40 | par {|i| $i })
        let e = ($rows | par emit)
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        assert-eq $e.truncated true "truncated"
        assert-true ("findings" not-in ($e | columns)) "no findings"
        assert-true ($e.bytes > 50) "census bytes"
        assert-true ($e.n > 0) "n present"
        assert-true ($e.n_ok != null) "n_ok"
        assert-true ($e.n_err != null) "n_err"
    })
    (t "collect --timeout 0sec does not hang" {
        let r = (jobs spawn { sleep 2sec; 1 } --tag hang)
        let t0 = (date now)
        let c = (jobs collect --timeout 0sec)
        let dt = ((date now) - $t0)
        assert-true ($dt < 1sec) "did not hang"
        assert-eq ($c | length) 0 "still running omitted"
        assert-eq (jobs list | get 0.status) "running" "stays on list"
        let _ = (jobs cancel $r.job_id)
    })
    (t "spawn at ceiling+1 refuses" {
        let saved = $env.NU_PAR.ceiling
        $env.NU_PAR = ($env.NU_PAR | upsert ceiling 1)
        let a = (jobs spawn { sleep 2sec; 1 } --tag cap-a)
        let b = (jobs spawn { 2 } --tag cap-b)
        assert-eq $a.status "running" "first accepted"
        assert-eq $b.ok false "second refused"
        assert-eq $b.error "budget" "budget error"
        assert-true ($b.budget.ceiling == 1) "budget record"
        assert-true ((jobs-running-safe) <= 1) "inflight <= ceiling"
        let _ = (jobs cancel $a.job_id)
        $env.NU_PAR = ($env.NU_PAR | upsert ceiling $saved)
    })
    (t "cancel stamps row" {
        let a = (jobs spawn { sleep 5sec; 1 } --tag can)
        let k = (jobs cancel $a.job_id)
        assert-eq $k.ok true "cancel ok"
        assert-eq $k.cancelled true "cancelled true"
        assert-eq $k.meta.verb "jobs.cancel" "cancel stamped"
        assert-eq $k.meta.tag "can" "cancel meta tag"
        let listed = (jobs list)
        assert-eq ($listed | get 0.status) "cancelled" "status"
        assert-true (($listed | get 0.finished) != null) "finished stamped by cancel"
        assert-true (($listed | get 0.elapsed) != null) "elapsed stamped"
        assert-eq (jobs status | get inflight) 0 "inflight decremented"
        let c = (jobs collect --timeout 0sec)
        assert-eq ($c | length) 1 "collect includes cancelled"
        assert-eq ($c | get 0.status) "cancelled" "untouched"
    })
    (t "out-of-band kill vanished" {
        let a = (jobs spawn { sleep 5sec; 1 } --tag van)
        job kill $a.job_id
        let listed = (jobs list)
        assert-eq ($listed | get 0.status) "failed" "reconciled failed"
        assert-eq ($listed | get 0.error) "vanished" "vanished"
        assert-true (($listed | get 0.finished) != null) "finished stamped"
        let saved = $env.NU_PAR.ceiling
        $env.NU_PAR = ($env.NU_PAR | upsert ceiling 1)
        # inflight must not still count the vanished row
        let b = (jobs spawn { 1 } --tag van-next)
        $env.NU_PAR = ($env.NU_PAR | upsert ceiling $saved)
        assert-true ($b.error? != "budget") "spawn not budget-refused"
        assert-eq $b.status "running" "accepted"
        let _ = (jobs collect --timeout 2sec)
    })
    (t "undrained completed is not vanished" {
        let a = (jobs spawn { 42 } --tag undrained)
        wait-gone $a.job_id
        # native job list empty; message should still be pending until harvest
        let listed = (jobs list)
        assert-eq ($listed | get 0.status) "completed" "list did not mark vanished"
        let err = ($listed | get 0.error)
        assert-true (($err == null) or ($err != "vanished")) "not vanished"
        let c = (jobs collect --timeout 0sec)
        assert-eq ($c | get 0.status) "completed" "collect finalized"
        assert-eq (jobs read undrained) 42 "payload"
    })
    (t "read is peek not pop" {
        let _ = (jobs spawn { [1 2 3] } --tag peek)
        let _ = (jobs collect --timeout 2sec)
        let a = (jobs read peek)
        let b = (jobs read peek)
        assert-eq $a [1 2 3] "first read"
        assert-eq $b [1 2 3] "second read same"
        assert-eq (jobs list | get 0.status) "completed" "row unchanged"
        assert-eq (jobs list | length) 1 "not popped"
    })
    (t "registry --env spawn then list" {
        let r = (jobs spawn { "keep" } --tag env-keep)
        let listed = (jobs list)
        assert-eq ($listed | length) 1 "list sees spawn"
        assert-eq ($listed | get 0.tag) "env-keep" "tag"
        assert-eq ($listed | get 0.job_id) $r.job_id "same id"
        let _ = (jobs collect --timeout 2sec)
    })
    (t "duplicate tag refused" {
        let _ = (jobs spawn { sleep 1sec; 1 } --tag dup)
        let b = (jobs spawn { 2 } --tag dup)
        assert-eq $b.ok false "refused"
        assert-eq $b.error "duplicate tag" "error"
        let _ = (jobs collect --timeout 2sec)
    })
    (t "jobs status has cores and knobs" {
        let s = (jobs status)
        assert-true ($s.cores >= 1) "cores"
        assert-true ($s.ceiling >= 1) "ceiling"
        assert-true ($s.reserved_cores != null) "reserved_cores"
        assert-true ($s.min_items_per_worker != null) "min_items_per_worker"
        assert-true ($s.inflight != null) "inflight"
        assert-true ($s.policy != null) "policy"
        assert-eq $s.meta.verb "jobs.status" "status stamped"
    })
    (t "finished jobs never marked vanished (stress)" {
        # Jobs that send then exit while harvest is running must never be `vanished`.
        # Snapshot-before-drain ordering is what keeps this true; hammer `list` while they land.
        let n = 10
        for i in 0..<$n {
            let ms = (($i * 7) mod 50)
            let _ = (jobs spawn { sleep ($ms * 1ms); $i } --tag $"st($i)")
        }
        let t0 = (date now)
        loop {
            let l = (jobs list)
            if ($l | where status == "running" | is-empty) { break }
            if ((date now) - $t0) > 5sec { error make {msg: "stress jobs did not finish"} }
        }
        let l = (jobs list)
        assert-eq ($l | length) $n "all rows"
        assert-true ($l | where error == "vanished" | is-empty) "none vanished"
        assert-true ($l | where status != "completed" | is-empty) "all completed"
        for i in 0..<$n {
            assert-eq (jobs read $"st($i)") $i $"payload st($i)"
        }
    })
    (t "jobs stash completed-on-arrival" {
        let r = ([1 2 3] | jobs stash --tag s)
        assert-eq $r.status "completed" "status"
        assert-eq $r.job_id null "no native job"
        assert-true ($r.bytes > 0) "bytes"
        assert-eq $r.length 3 "length"
        assert-true ("output" not-in ($r | columns)) "receipt has no body"
        assert-eq $r.meta.verb "jobs.stash" "stash stamped"
        assert-eq (jobs read s) [1 2 3] "readable"
        assert-true ("output" not-in (jobs inspect s | columns)) "inspect no body"
        assert-eq (jobs collect --timeout 0sec | length) 1 "collect includes it"
        assert-eq (jobs status | get inflight) 0 "not inflight"
        let dup = ([9] | jobs stash --tag s)
        assert-eq $dup.error "duplicate tag" "duplicate refused"
        let auto = ("x" | jobs stash)
        assert-true ($auto.tag | str starts-with "stash:") "stash prefix"
        assert-true ($auto.tag != "s") "not the tagged row"
        assert-eq (jobs fetch $auto.tag) "x" "auto fetchable"
    })
    (t "jobs emit quarantines over cap" {
        let rows = (1..40 | par {|i| $i })
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 50)
        let e = ($rows | jobs emit --tag q)
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        assert-eq $e.truncated true "truncated"
        assert-true ("findings" not-in ($e | columns)) "no findings inline"
        assert-eq $e.tag "q" "tag on envelope"
        assert-eq (jobs fetch q) $rows "full findings retrievable"
        assert-eq (jobs list | get 0.status) "completed" "registry row"
        let small = ([{a: 1}] | jobs emit --tag small)
        assert-eq $small.truncated false "under cap"
        assert-true ("findings" in ($small | columns)) "findings inline"
        assert-true ("tag" not-in ($small | columns)) "no tag when nothing stored"
        assert-eq (jobs list | length) 1 "nothing stashed under cap"
    })
    (t "exit-gate spawn collect read" {
        let r = (jobs spawn { 1..8 | par {|i| $i * $i } } --tag sq)
        assert-eq $r.status "running" "receipt running"
        assert-eq $r.tag "sq" "tag"
        let c = (jobs collect --timeout 5sec)
        assert-eq ($c | length) 1 "one finished"
        assert-eq ($c | get 0.ok) true "ok"
        assert-true (($c | get 0.bytes) != null) "bytes"
        assert-true (($c | get 0.type) != null) "type"
        assert-true ("output" not-in ($c | columns)) "no values on collect"
        let table = (jobs read sq)
        assert-eq ($table | length) 8 "eight rows"
        assert-eq ($table | get value) [1 4 9 16 25 36 49 64] "squares"
    })
    (t "par cap resolver" {
        let saved = $env.NU_PAR.max_inline_bytes
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 50)
        assert-eq (par cap) 50 "explicit"
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        let c = (par cap)
        assert-true ($c >= 1) "default int"
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes $saved)
    })
    (t "jobs read over cap declines" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 20)
        let v = (1..20 | each { "xxxx" } | str join)
        let _ = ($v | jobs stash --tag big)
        let i = (jobs inspect big)
        assert-true ("output" not-in ($i | columns)) "inspect no body"
        assert-true ("disclosed" not-in ($i | columns)) "inspect is not a decline"
        assert-eq $i.meta.verb "jobs.inspect" "inspect stamped"
        assert-true ($i.bytes > 20) "bytes over cap"
        let s = (jobs fetch big | shape)
        assert-eq $i.bytes $s.bytes "inspect bytes from shape"
        assert-eq $i.type $s.type "inspect type from shape"
        let d = (jobs read big)
        assert-eq $d.ok true "decline ok"
        assert-eq $d.disclosed false "not disclosed"
        assert-eq $d.retrieve $"jobs fetch ($d.tag | to nuon --raw)" "retrieve"
        assert-eq $d.tag "big" "tag"
        assert-eq $d.meta.verb "jobs.read" "read stamped"
        assert-eq (jobs fetch big) $v "full body"
        assert-eq (jobs list | length) 1 "did not re-stash"
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
    })
    (t "missing running cancelled are data" {
        let miss = (jobs inspect nope)
        assert-eq $miss.ok false "inspect missing"
        assert-eq $miss.meta.verb "jobs.inspect" "inspect stamped"
        let rm = (jobs read nope)
        assert-eq $rm.ok false "read missing"
        assert-eq $rm.disclosed false "read not disclosed"
        assert-eq (jobs fetch nope).ok false "fetch missing"
        let a = (jobs spawn { sleep 5sec; 1 } --tag run)
        let rr = (jobs read run)
        assert-eq $rr.ok false "read running"
        assert-eq $rr.error "still running" "running error"
        assert-eq (jobs fetch run).error "still running" "fetch running"
        let k = (jobs cancel $a.job_id)
        assert-eq $k.ok true "cancel ok"
        assert-eq $k.cancelled true "cancelled"
        let missc = (jobs cancel 999999)
        assert-eq $missc.ok false "missing cancel ok"
        assert-eq $missc.cancelled false "missing not cancelled"
        let already = (jobs cancel $a.job_id)
        assert-eq $already.ok false "already cancelled ok"
        assert-eq $already.cancelled false "already not cancelled"
        let fc = (jobs fetch run)
        assert-eq $fc.ok false "fetch cancelled"
        assert-eq $fc.status "cancelled" "cancelled status"
    })
    (t "retrieve quotes tags" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 20)
        let v = (1..20 | each { "xxxx" } | str join)
        let _ = ($v | jobs stash --tag "my tag")
        let d = (jobs read "my tag")
        assert-eq $d.retrieve "jobs fetch \"my tag\"" "space quoted"
        assert-eq (jobs fetch "my tag") $v "fetch space tag"
        let qtag = "say \"hi\""
        let _ = ($v | jobs stash --tag $qtag)
        let dq = (jobs read $qtag)
        assert-eq $dq.retrieve $"jobs fetch ($qtag | to nuon --raw)" "quote quoted"
        assert-eq (jobs fetch $qtag) $v "fetch quoted tag"
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
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
