# Claim a run-scoped scratch directory without sharing it with a concurrent suite.
# The first run in a second uses `<stamp>_<lane>`; collisions use `<stamp>_<NN>_<lane>`.
export def "test scratch" [
    test_runs: string
    lane: string
]: nothing -> string {
    mkdir $test_runs
    let stamp = (date now | format date '%Y%m%d_%H%M%S')
    mut collision = 0

    mut claimed_path = ""
    while ($claimed_path | is-empty) {
        let suffix = (
            if $collision == 0 {
                $stamp
            } else {
                let nn = (
                    if $collision < 10 { $"0($collision)" } else { $collision | into string }
                )
                $"($stamp)_($nn)"
            }
        )
        let candidate = ($test_runs | path join $"($suffix)_($lane)")
        mkdir $candidate
        let claimed = (try {
            $"pid=($nu.pid)" | save --raw ($candidate | path join .claim)
            true
        } catch {|e|
            if $e.msg == "Destination file already exists" {
                false
            } else {
                error make $e
            }
        })
        if $claimed {
            $claimed_path = $candidate
        } else {
            $collision = $collision + 1
        }
    }
    $claimed_path
}
