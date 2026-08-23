# Child `nu -n` tests for rg wrapper v1. Run:
#   nu -n mcp/nushell-mcp/tests/rg-v1.nu

const MODULES_DIR = (path self | path dirname | path dirname | path join modules)
const NU_LIB_DIRS = [$MODULES_DIR]
const JOBS_MBOX = 0x4A4F4253
const CLI = (path self | path dirname | path dirname | path join deps cli)

if ($CLI | path exists) {
    let path = (
        if ($env.PATH | describe) =~ "list" { $env.PATH } else { $env.PATH | split row (char esep) }
    )
    $env.PATH = ($path | prepend $CLI)
}

use par *
use jobs *
use dataspection *
use rg *

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

if (which rg | is-empty) {
    let skip = [{name: "skipped: rg not on PATH", ok: true, error: "rg not on PATH"}]
    print -e ($skip | to nuon --raw)
    $skip | select name ok
    return
}

let FIX = ($nu.temp-dir | path join $"rg-v1-($nu.pid)")
mkdir $FIX
"needle aaa needle\nplain line\nbbb needle\n" | save --force ($FIX | path join "a.txt")
"needle ccc\n" | save --force ($FIX | path join "b.txt")
"zzz\n" | save --force ($FIX | path join "c.txt")
# many hits for over-cap
for i in 0..<20 {
    (0..<10 | each { "needle line" } | str join (char nl)) | save --force ($FIX | path join $"m($i).txt")
}

$env.NU_PAR = ($env.NU_PAR | upsert max_workers null | upsert policy "auto")

let results = [
    (t "no match" {
        let r = (rg nosuchpatternzzzz $FIX)
        assert-eq $r.ok true "exit 1 is ok"
        assert-eq $r.mode "json" "json"
        assert-eq $r.n 0 "n"
        assert-eq $r.truncated false "not truncated"
        assert-eq $r.findings [] "empty findings"
        assert-missing $r "spine" "no spine"
        assert-missing $r "text" "no text"
        assert-missing $r "tag" "no tag"
    })
    (t "unknown flag" {
        let r = (rg --bogus)
        assert-eq $r.ok false "ok false"
        assert-true (($r.error | default "") != "") "error"
        assert-missing $r "findings" "no findings"
        assert-missing $r "spine" "no spine"
        assert-missing $r "text" "no text"
    })
    (t "small json query" {
        let r = (rg needle ($FIX | path join "a.txt") ($FIX | path join "b.txt"))
        assert-eq $r.ok true "ok"
        assert-eq $r.mode "json" "json"
        assert-eq $r.n 3 "matched_lines"
        assert-eq $r.n_files 2 "files"
        assert-true ($r.bytes > 0) "bytes"
        assert-eq $r.truncated false "inline"
        assert-eq ($r.findings | length) 3 "three rows"
        assert-eq ($r.findings | get kind | uniq) [match] "kind match"
        assert-missing $r "spine" "no spine"
        assert-missing $r "text" "no text"
        assert-missing $r "tag" "no tag"
        assert-eq $r.meta.verb "rg" "stamped"
        assert-true ("--json" in $r.args) "json injected"
        assert-eq ($r.args | where {|a| $a == "--json"} | length) 1 "json once"
    })
    (t "json not doubled" {
        let r = (rg --json needle ($FIX | path join "b.txt"))
        assert-eq ($r.args | where {|a| $a == "--json"} | length) 1 "still one"
        assert-eq $r.mode "json" "json"
        assert-eq $r.n 1 "one"
    })
    (t "text mode version and list" {
        let v = (rg --version)
        assert-eq $v.mode "text" "version text"
        assert-eq $v.n 0 "n 0"
        assert-true (($v.text | default "") != "") "version text present"
        let l = (rg --json -l needle $FIX)
        assert-eq $l.mode "text" "list text"
        assert-true (($l.text | default "") != "") "file list"
        assert-missing $l "findings" "no findings"
    })
    (t "context rows" {
        let r = (rg -C 1 needle ($FIX | path join "a.txt"))
        assert-eq $r.mode "json" "json"
        assert-true (($r.findings | where kind == "context" | length) > 0) "has context"
        let ctx = ($r.findings | where kind == "context" | first)
        assert-eq $ctx.col null "context col null"
        let r2 = (rg needle -C 1 ($FIX | path join "a.txt"))
        assert-true (($r2.findings | where kind == "context" | length) > 0) "C after pattern"
    })
    (t "-e pattern" {
        let r = (rg -e needle ($FIX | path join "b.txt"))
        assert-eq $r.ok true "ok"
        assert-eq $r.n 1 "one"
        assert-eq $r.mode "json" "json"
    })
    (t "over cap json spine" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 80)
        let r = (rg needle $FIX)
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        assert-eq $r.truncated true "truncated"
        assert-missing $r "findings" "no findings"
        assert-true ("spine" in ($r | columns)) "spine"
        let hits = ($r.spine | get hits)
        let files = ($r.spine | get file)
        assert-eq ($hits) ($hits | sort --reverse) "hits desc"
        assert-eq $r.tag "rg:0" "tag rg:0"
        assert-eq (jobs inspect rg:0 | get ok) true "inspect ok"
        assert-true ("output" not-in (jobs inspect rg:0 | columns)) "inspect no body"
        let full = (jobs fetch rg:0)
        assert-true (($full | length) > 0) "fetched table"
        assert-eq ($full | columns | sort) [col file kind line match] "finding cols"
    })
    (t "text over cap" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 10)
        let r = (rg --version)
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        assert-eq $r.mode "text" "text"
        assert-eq $r.truncated true "truncated"
        assert-missing $r "text" "text omitted"
        assert-true ($r.tag != null) "tag"
        let body = (jobs fetch $r.tag)
        assert-true (($body | str length) > 10) "stashed string"
    })
    (t "two over-cap tags" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 80)
        let a = (rg needle $FIX)
        let b = (rg needle $FIX)
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        assert-eq $a.tag "rg:0" "first"
        assert-eq $b.tag "rg:1" "second"
    })
    (t "inside a job no stash" {
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes 80)
        let fix = $FIX
        let _ = (jobs spawn { rg needle $fix } --tag bg)
        let _ = (jobs collect --timeout 5sec)
        $env.NU_PAR = ($env.NU_PAR | upsert max_inline_bytes null)
        let envl = (jobs fetch bg)
        assert-eq $envl.truncated false "in-job not truncated"
        assert-missing $envl "tag" "no rg tag"
        assert-true ("findings" in ($envl | columns)) "findings inline"
        assert-true (($envl.findings | length) > 0) "has hits"
        assert-eq (jobs list | length) 1 "only the job row"
        assert-eq (jobs list | get 0.tag) "bg" "job tag"
    })
    (t "rg absent" {
        let r = (with-env { PATH: [], Path: [] } { rg needle })
        assert-eq $r.ok false "ok false"
        assert-true (($r.error | default "") | str contains "not found") "not found"
        assert-true ("trace" in ($r | columns)) "rg keeps trace"
        assert-true (($r.trace | default "") | str contains "not found") "trace names miss"
        assert-eq (jobs list | length) 0 "nothing stashed"
    })
    (t "help rg is wrapper" {
        let h = (help rg | to text)
        assert-true ($h | str contains "json") "doc mentions json"
        assert-true ($h | str contains "wrapped") "doc mentions wrapped"
    })
]

try { rm -r $FIX } catch { }

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
