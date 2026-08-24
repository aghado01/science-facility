# rg — agent-facing search wrapper. Consumes `process capture`, not ordinary `xq`.
# Injects `--json` once. Mode is detected on the return path.

use core/capture.nu ["process capture"]
use core/census.nu [shape]
use core/spine.nu *
use core/meta.nu ["meta stamp"]
use core/failure.nu ["failure fields"]
use core/execution.nu ["execution context"]
use core/stream.nu ["stream bytes"]
use jobs ["jobs stash"]
use par ["par cap"]

def rg-has-json [args: list]: nothing -> bool {
    $args | any {|a| $a == "--json"}
}

def rg-strip-nl [s: string]: nothing -> string {
    $s | str replace --regex "\r?\n$" ""
}

def rg-error-short [stderr: string]: nothing -> string {
    let line = ($stderr | lines | first | default "")
    if ($line | str length) <= 240 { $line } else { $line | str substring ..<240 }
}

def rg-bytes-only [obj]: nothing -> bool {
    let d = (try { $obj | describe } catch { "other" })
    if not ($d | str starts-with "record") { return false }
    let cols = (try { $obj | columns } catch { [] })
    if not ("bytes" in $cols) { return false }
    let text = (try { $obj.text } catch { null })
    ($text == null) or ((try { $text | describe } catch { "other" }) != "string")
}

def rg-elapsed-from-summary [sum]: nothing -> any {
    let et = (try { $sum.data.elapsed_total } catch { null })
    if $et == null { return null }
    let secs = ($et.secs? | default 0)
    let nanos = ($et.nanos? | default 0)
    try { ($secs * 1sec) + ($nanos * 1ns) } catch { null }
}

# Parse rg --json stdout. `{mode: json, findings, n, n_files, elapsed}` or `{mode: text}`.
def rg-parse [stdout: string] {
    let lines = ($stdout | lines | where {|l| ($l | str trim) != ""})
    if ($lines | is-empty) {
        return {mode: "json", findings: [], n: 0, n_files: 0, elapsed: null}
    }
    let parsed = (
        try { $lines | each {|l| $l | from json } } catch { null }
    )
    if $parsed == null {
        return {mode: "text"}
    }
    if ($parsed | any {|r| not (($r | describe) | str starts-with "record")}) {
        return {mode: "text"}
    }
    if ($parsed | any {|r| ($r.type? | default "") == ""}) {
        return {mode: "text"}
    }
    let events = ($parsed | where type in ["match" "context"])
    let encoding = (
        try {
            $events | any {|ev|
                (rg-bytes-only ($ev.data.path? | default {})) or (rg-bytes-only ($ev.data.lines? | default {}))
            }
        } catch { false }
    )
    if $encoding {
        return {mode: "encoding", error: "unsupported encoding"}
    }
    let raw_findings = (
        $parsed
        | where type in ["match" "context"]
        | each {|ev|
            let kind = $ev.type
            let file = (try { $ev.data.path.text } catch { "" }) | default ""
            let line = (try { $ev.data.line_number } catch { 0 })
            let text = (try { $ev.data.lines.text } catch { "" }) | default ""
            let subs = (try { $ev.data.submatches } catch { [] }) | default []
            let col = (
                if $kind == "match" and (not ($subs | is-empty)) {
                    try { $subs | first | get start } catch { null }
                } else { null }
            )
            {file: $file, line: $line, col: $col, kind: $kind, match: (rg-strip-nl $text)}
        }
    )
    # Empty is `[]`, not a typed empty table.
    let findings = (if ($raw_findings | is-empty) { [] } else { $raw_findings })
    let sum = (try { $parsed | where type == "summary" | first } catch { null })
    let n = (if $sum != null { try { $sum.data.stats.matched_lines } catch { ($findings | where kind == "match" | length) } } else { $findings | where kind == "match" | length })
    let n_files = (if $sum != null { try { $sum.data.stats.searches_with_match } catch { ($findings | get file | uniq | length) } } else { $findings | get file | uniq | length })
    let elapsed = (rg-elapsed-from-summary $sum)
    {mode: "json", findings: $findings, n: $n, n_files: $n_files, elapsed: $elapsed}
}

def rg-fail [args: list, error: string, elapsed, --trace: string] {
    mut rec = {
        ok: false
        mode: "text"
        n: 0
        n_files: 0
        elapsed: $elapsed
        bytes: 0
        truncated: false
        args: $args
        error: $error
    }
    if $trace != null and (($trace | str length) > 0) {
        $rec = ($rec | insert trace $trace)
    }
    $rec | meta stamp --verb rg
}

# Search via ripgrep. `--wrapped`; injects `--json` once if absent. Mode is detected
# on the return path: JSON events → `json`, anything else → `text`. Envelope:
# `{ok, mode, n, n_files, elapsed, bytes, truncated, args, error?, trace?, tag?, findings?, spine?, text?}`.
# json: `findings` under cap, `spine`+stash over cap. text: `text` under cap, omit+stash over.
# Cap is `par cap`. Inside a job, never stash. Foreground `par` worker over cap: `ok: false`,
# no tag, `truncated: false`. Tag is allocated by `jobs stash --prefix rg` after storage.
# Capture/spawn failures keep the short `error` and `trace` when one was captured.
# `help rg` is this contract; `^rg` is the escape.
export def --env --wrapped main [...args] {
    let forwarded = (if (rg-has-json $args) { $args } else { ["--json"] ++ $args })
    let piped = ($in | describe) != "nothing"
    let stdin = $in
    let capd = (
        try {
            if $piped {
                $stdin | process capture rg ...$forwarded
            } else {
                process capture rg ...$forwarded
            }
        } catch {|e|
            let f = (failure fields $e)
            {ok: false, error: $f.error, trace: $f.trace, exit_code: null, stdout: "", stderr: "", elapsed: 0sec}
        }
    )
    let elapsed_wall = ($capd.elapsed? | default 0sec)
    if ($capd.ok? == false) {
        return (rg-fail $forwarded ($capd.error? | default "not found: rg") $elapsed_wall --trace ($capd.trace? | default ""))
    }
    let stdout = ($capd.stdout | default "")
    let stderr = ($capd.stderr | default "")
    let code = $capd.exit_code
    if $code != null and $code >= 2 {
        let err = (rg-error-short $stderr)
        return (rg-fail $forwarded (if $err == "" { $"rg exit ($code)" } else { $err }) $elapsed_wall)
    }
    if (($stdout | describe) == "binary") or (($stderr | describe) == "binary") {
        return (rg-fail $forwarded "binary stream" $elapsed_wall)
    }
    let parsed = (rg-parse $stdout)
    if $parsed.mode == "encoding" {
        return (rg-fail $forwarded ($parsed.error? | default "unsupported encoding") $elapsed_wall)
    }
    let ctx = (execution context)
    if $parsed.mode == "text" {
        let sm = ($stdout | stream bytes)
        if $sm.ok == false {
            return (rg-fail $forwarded $sm.error $elapsed_wall)
        }
        let bytes = $sm.bytes
        let over = ($bytes > (par cap))
        mut rec = {
            ok: true
            mode: "text"
            n: 0
            n_files: 0
            elapsed: $elapsed_wall
            bytes: $bytes
            truncated: false
            args: $forwarded
        }
        if $ctx.in_job or (not $over) {
            $rec = ($rec | insert text $stdout)
        } else if not $ctx.owns_registry {
            $rec = ($rec | upsert ok false | insert error "over cap in a par worker; wrap the batch in jobs spawn")
        } else {
            let st = ($stdout | jobs stash --prefix "rg")
            if ($st.ok? == false) {
                $rec = ($rec | upsert ok false | insert error ($st.error? | default "stash failed"))
            } else {
                $rec = ($rec | upsert truncated true | insert tag $st.tag)
            }
        }
        return ($rec | meta stamp --verb rg)
    }
    let findings = $parsed.findings
    let elapsed = (if $parsed.elapsed != null { $parsed.elapsed } else { $elapsed_wall })
    let bytes = ($findings | shape | get bytes)
    let over = ($bytes != null and $bytes > (par cap))
    mut rec = {
        ok: true
        mode: "json"
        n: $parsed.n
        n_files: $parsed.n_files
        elapsed: $elapsed
        bytes: ($bytes | default 0)
        truncated: false
        args: $forwarded
    }
    if $ctx.in_job or (not $over) {
        $rec = ($rec | insert findings $findings)
    } else if not $ctx.owns_registry {
        $rec = ($rec | upsert ok false | insert error "over cap in a par worker; wrap the batch in jobs spawn")
    } else {
        let st = ($findings | jobs stash --prefix "rg")
        let sp = (
            $findings | spine file | rename --column {key: "file", n: "hits"}
        )
        $rec = ($rec | insert spine $sp)
        if ($st.ok? == false) {
            $rec = ($rec | upsert ok false | insert error ($st.error? | default "stash failed"))
        } else {
            $rec = ($rec | upsert truncated true | insert tag $st.tag)
        }
    }
    $rec | meta stamp --verb rg
}
