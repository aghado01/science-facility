# process capture — unbounded external run. No cap, no stash, no par/jobs.
# Named export, not `main`. xq and rg consume this; agents use `xq`.

def capture-miss [cmd: string, elapsed] {
    {
        ok: false
        error: $"not found: ($cmd)"
        cmd: $cmd
        args: []
        stdout: ""
        stderr: ""
        exit_code: null
        elapsed: $elapsed
    }
}

# Run `cmd` with opaque argv. Always full streams. Missing binary is data, not a throw.
# Attach stdin only when `$in` is not `nothing`.
export def --wrapped "process capture" [...args] {
    if ($args | is-empty) {
        return {
            ok: false
            error: "process capture: empty argv"
            cmd: ""
            args: []
            stdout: ""
            stderr: ""
            exit_code: null
            elapsed: 0sec
        }
    }
    let cmd = ($args | first | into string)
    let rest = ($args | skip 1)
    let piped = ($in | describe) != "nothing"
    let stdin = $in
    let t0 = (date now)
    let ran = (
        try {
            if $piped {
                $stdin | ^$cmd ...$rest | complete
            } else {
                ^$cmd ...$rest | complete
            }
        } catch {
            null
        }
    )
    let elapsed = ((date now) - $t0)
    if $ran == null {
        return (capture-miss $cmd $elapsed)
    }
    {
        stdout: ($ran.stdout | default "")
        stderr: ($ran.stderr | default "")
        exit_code: $ran.exit_code
        elapsed: $elapsed
    }
}
