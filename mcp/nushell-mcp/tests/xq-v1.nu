# Child `nu -n` tests for xq v1. Run:
#   nu -n mcp/nushell-mcp/tests/xq-v1.nu

const MODULES_DIR = (path self | path dirname | path dirname | path join modules)
const NU_LIB_DIRS = [$MODULES_DIR]
const JOBS_MBOX = 0x4A4F4253
const EXE = $nu.current-exe

use par *
use jobs *
use dataspection *
use xq *
use core/capture.nu ["process capture"]

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

def --env t [name: string, fn: closure] {
    reset-jobs
    try {
        do $fn
        {name: $name, ok: true, error: null}
    } catch {|e|
        {name: $name, ok: false, error: ($e.msg | lines | first | default $e.msg)}
    }
}

def assert-missing [rec: record, col: string, msg: string] {
    if $col in ($rec | columns) { error make {msg: $msg} }
}

$env.NU_PAR = ($env.NU_PAR | upsert max_workers null | upsert policy "auto")

let results = [
    (t "exit 0 stdout inline" {
        let r = (xq $EXE -n -c "print 'hello'")
        assert-eq $r.ok true "ok"
        assert-eq $r.exit_code 0 "exit"
        assert-eq $r.cmd $EXE "cmd is args.0"
        assert-eq $r.args [-n -c "print 'hello'"] "args exclude cmd"
        assert-eq $r.truncated false "not truncated"
        assert-missing $r "tag" "no tag"
        assert-missing $r "error" "no error"
        assert-true ("hello" in $r.stdout) "stdout"
        assert-eq $r.stdout_bytes ($r.stdout | str length --utf-8-bytes) "stdout_bytes"
        assert-eq $r.meta.verb "xq" "stamped"
        assert-true (($r.elapsed | describe) =~ 'duration') "elapsed duration"
    })
    (t "exit non-zero stderr inline" {
        let r = (xq $EXE -n -c "exit 2")
        assert-eq $r.ok false "ok from exit"
        assert-eq $r.exit_code 2 "exit_code"
        assert-eq $r.truncated false "inline"
        assert-missing $r "error" "child fail is not wrapper error"
        assert-true ("stderr" in ($r | columns)) "stderr present"
    })
    (t "not found is data" {
        let r = (xq definitely-not-a-cmd-xyz)
        assert-eq $r.ok false "ok"
        assert-eq $r.exit_code null "exit null"
        assert-true (($r.error | default "") | str starts-with "not found:") "not found"
        assert-eq (jobs list | length) 0 "nothing stashed"
        let c = (process capture definitely-not-a-cmd-xyz)
        assert-eq $c.ok false "capture ok false"
        assert-eq $c.exit_code null "capture exit null"
    })
    (t "empty argv" {
        let r = (xq)
        assert-eq $r.ok false "ok"
        assert-true (($r.error | default "") | str contains "empty") "empty"
    })
    (t "stdin passthrough" {
        let r = ("abc" | xq $EXE -n --stdin -c '$in')
        assert-eq $r.ok true "ok"
        assert-true ("abc" in $r.stdout) "echoed"
        let bare = (xq $EXE -n -c '$in')
        assert-eq $bare.ok true "bare ok"
        assert-true (($bare.stdout | str trim | str length) == 0) "no stdin attached"
    })
    (t "over cap stashes" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 50)
        let r = (xq $EXE -n -c "1..2000 | to text")
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        assert-eq $r.truncated true "truncated"
        assert-missing $r "stdout" "no stdout"
        assert-missing $r "stderr" "no stderr"
        assert-true ($r.tag != null) "tag"
        assert-true ($r.tag | str starts-with "xq:") "xq tag"
        let body = (jobs fetch $r.tag)
        assert-true (($body.stdout | str length) > 50) "stashed stdout"
        assert-eq (jobs list | length) 1 "one row"
        assert-eq (jobs list | get 0.job_id) null "stash row"
        assert-eq (jobs list | get 0.status) "completed" "completed"
    })
    (t "two over-cap tags monotonic" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 50)
        let a = (xq $EXE -n -c "1..2000 | to text")
        let b = (xq $EXE -n -c "1..2000 | to text")
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        assert-true ($a.tag != $b.tag) "distinct tags"
        assert-eq (jobs list | length) 2 "two rows"
    })
    (t "inside a job no stash" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 50)
        let exe = $EXE
        let _ = (jobs spawn { xq $exe -n -c "1..2000 | to text" } --tag bg)
        let _ = (jobs collect --timeout 5sec)
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        let envl = (jobs fetch bg)
        assert-eq $envl.truncated false "in-job not truncated"
        assert-missing $envl "tag" "no xq tag"
        assert-true (($envl.stdout | str length) > 50) "full stdout"
        assert-eq (jobs list | length) 1 "only the job row"
        assert-eq (jobs list | get 0.tag) "bg" "job tag"
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
