# process capture — unbounded external run. No cap, no stash, no par/jobs.
# Named export, not `main`. xq and rg consume this; agents use `xq`.
# `ok` is capture success, independent of child exit code.

use ./failure.nu ["failure fields"]

def capture-not-found [err: string, trace: string]: nothing -> bool {
    let blob = ($"($err)\n($trace)" | str lowercase)
    ($blob =~ 'not found') or ($blob =~ 'cannot find') or ($blob =~ 'executable not found')
}

def capture-fail [
    cmd: string
    rest: list
    error: string
    elapsed
    --trace: string
] {
    mut rec = {
        ok: false
        error: $error
        cmd: $cmd
        args: $rest
        stdout: ""
        stderr: ""
        exit_code: null
        elapsed: $elapsed
    }
    if $trace != null {
        $rec = ($rec | insert trace $trace)
    }
    $rec
}

# Run `cmd` with opaque argv. Always full streams. Missing binary is data, not a throw.
# Attach stdin only when `$in` is not `nothing`.
# Success includes `ok: true` even when the child exit code is non-zero.
export def --wrapped "process capture" [...args] {
    if ($args | is-empty) {
        return (capture-fail "" [] "process capture: empty argv" 0sec)
    }
    let cmd = ($args | first | into string)
    let rest = ($args | skip 1)
    let piped = ($in | describe) != "nothing"
    let stdin = $in
    let t0 = (date now)
    try {
        let ran = (
            if $piped {
                $stdin | ^$cmd ...$rest | complete
            } else {
                ^$cmd ...$rest | complete
            }
        )
        {
            ok: true
            cmd: $cmd
            args: $rest
            stdout: ($ran.stdout | default "")
            stderr: ($ran.stderr | default "")
            exit_code: $ran.exit_code
            elapsed: ((date now) - $t0)
        }
    } catch {|e|
        let f = (failure fields $e)
        let elapsed = ((date now) - $t0)
        let err = (
            if (capture-not-found $f.error $f.trace) {
                $"not found: ($cmd)"
            } else {
                $f.error
            }
        )
        capture-fail $cmd $rest $err $elapsed --trace $f.trace
    }
}
