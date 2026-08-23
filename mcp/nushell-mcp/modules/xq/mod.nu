# xq — agent-facing execute-and-quarantine. Consumes `process capture`.
# Cap is stream UTF-8 bytes vs `par cap`, not `shape.bytes`.

use core/capture.nu ["process capture"]
use core/meta.nu ["meta stamp"]
use jobs ["jobs stash" "jobs list"]
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

# Execute an external. Under cap, streams inline. Over cap, stash `{stdout, stderr}`
# and return census + `tag`. Inside a job, never stash. `--wrapped`; argv forwarded.
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
    let in_job = ((job id) != 0)
    let over = (not $in_job) and (($out_b + $err_b) > (par cap))
    mut rec = {
        ok: ($code == 0)
        cmd: $cmd
        args: $tail
        exit_code: $code
        elapsed: $elapsed
        stdout_bytes: $out_b
        stderr_bytes: $err_b
        truncated: $over
    }
    if $over {
        let seq = (jobs list | length)
        let tag = $"xq:(xq-stem $cmd):($seq)"
        let st = ({stdout: $stdout, stderr: $stderr} | jobs stash --tag $tag)
        if ($st.ok? == false) {
            $rec = ($rec | insert error ($st.error? | default "stash failed") | insert tag $tag)
        } else {
            $rec = ($rec | insert tag $tag)
        }
    } else {
        $rec = ($rec | insert stdout $stdout | insert stderr $stderr)
    }
    $rec | meta stamp --verb xq
}
