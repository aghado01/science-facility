# xq — agent-facing execute-and-quarantine. Consumes `process capture`.
# Cap is stream UTF-8 bytes vs `par cap`, not `shape.bytes`.

use core/capture.nu ["process capture"]
use core/meta.nu ["meta stamp"]
use core/execution.nu ["execution context"]
use jobs ["jobs stash"]
use par ["par cap"]

def utf8-bytes [s]: nothing -> int {
    try { $s | str length --utf-8-bytes } catch { 0 }
}

def xq-stem [cmd: string]: nothing -> string {
    $cmd | path basename | str replace -a '.exe' '' | str replace -a '.EXE' ''
}

def xq-fail [cmd: string, args: list, error: string, elapsed] {
    {
        ok: false
        cmd: $cmd
        args: $args
        exit_code: null
        elapsed: $elapsed
        stdout_bytes: 0
        stderr_bytes: 0
        truncated: false
        error: $error
        stdout: ""
        stderr: ""
    } | meta stamp --verb xq
}

# Execute an external. Under cap, streams inline. Over cap in the foreground, stash
# `{stdout, stderr}` via `jobs stash --prefix` and return census + confirmed `tag`.
# Inside a job, never stash (job row is the quarantine). Foreground `par` worker over
# cap: `ok: false`, no tag, `truncated: false` — wrap the batch in `jobs spawn`.
# `--wrapped`; argv forwarded.
export def --env --wrapped main [...args] {
    if ($args | is-empty) {
        return (xq-fail "" [] "xq: empty argv" 0sec)
    }
    let cmd = ($args | first | into string)
    let tail = ($args | skip 1)
    let piped = ($in | describe) != "nothing"
    let stdin = $in
    let capd = (
        try {
            if $piped {
                $stdin | process capture ...$args
            } else {
                process capture ...$args
            }
        } catch {|e|
            {ok: false, error: ($e.msg | default "capture failed"), exit_code: null, stdout: "", stderr: "", elapsed: 0sec}
        }
    )
    if ($capd.ok? == false) {
        return (xq-fail $cmd $tail ($capd.error? | default "not found") ($capd.elapsed? | default 0sec))
    }
    let stdout = ($capd.stdout | default "")
    let stderr = ($capd.stderr | default "")
    let out_b = (utf8-bytes $stdout)
    let err_b = (utf8-bytes $stderr)
    let elapsed = ($capd.elapsed? | default 0sec)
    let code = $capd.exit_code
    let ctx = (execution context)
    let over = (($out_b + $err_b) > (par cap))
    mut rec = {
        ok: ($code == 0)
        cmd: $cmd
        args: $tail
        exit_code: $code
        elapsed: $elapsed
        stdout_bytes: $out_b
        stderr_bytes: $err_b
        truncated: false
    }
    if $ctx.in_job or (not $over) {
        $rec = ($rec | insert stdout $stdout | insert stderr $stderr)
    } else if not $ctx.owns_registry {
        $rec = ($rec | upsert ok false | insert error "over cap in a par worker; wrap the batch in jobs spawn")
    } else {
        let st = ({stdout: $stdout, stderr: $stderr} | jobs stash --prefix $"xq:(xq-stem $cmd)")
        if ($st.ok? == false) {
            $rec = ($rec | upsert ok false | insert error ($st.error? | default "stash failed"))
        } else {
            $rec = ($rec | upsert truncated true | insert tag $st.tag)
        }
    }
    $rec | meta stamp --verb xq
}
