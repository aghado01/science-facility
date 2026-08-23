# execution — job / worker / registry-owner context.
# Marker names are implementation, not launch surface or agent vocabulary.
# Not re-exported by the dataspection façade.

# {kind: "foreground"|"job"|"worker", owns_registry: bool, in_job: bool}
export def "execution context" []: nothing -> record {
    let jid = (try { job id } catch { 0 })
    if $jid != 0 {
        return {kind: "job", owns_registry: false, in_job: true}
    }
    if ($env.NU_EXEC_WORKER? | default "0") == "1" {
        let in_job = (($env.NU_EXEC_IN_JOB? | default "0") == "1")
        return {kind: "worker", owns_registry: false, in_job: $in_job}
    }
    {kind: "foreground", owns_registry: true, in_job: false}
}

# Record for `with-env` around `par-each`. Do not assign `$env.NU_EXEC_*` by hand.
export def "execution worker-env" [
    --in-job
]: nothing -> record {
    {
        NU_EXEC_WORKER: "1"
        NU_EXEC_IN_JOB: (if $in_job { "1" } else { "0" })
    }
}
