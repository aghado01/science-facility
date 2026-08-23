# outcome — declared outcome projection for par / jobs.
# Summarizes a value without modifying or wrapping it.
# Not re-exported by the dataspection façade.

def outcome-short [msg: string]: nothing -> string {
    let line = ($msg | lines | first | default "")
    if ($line | str length) <= 240 { $line } else { $line | str substring 0..239 }
}

def outcome-row [r]: nothing -> bool {
    let d = (try { $r | describe } catch { "other" })
    if not ($d | str starts-with "record") { return false }
    let cols = (try { $r | columns } catch { [] })
    if not ("ok" in $cols) { return false }
    (try { $r.ok | describe } catch { "other" }) == "bool"
}

# Shallow projection. Pipeline in: the original value is not altered.
# {declared: bool, ok: bool, error: string?}
export def "outcome project" []: any -> record {
    let val = $in
    let d = (try { $val | describe } catch { "other" })
    if ($d | str starts-with "record") {
        if not (outcome-row $val) {
            return {declared: false, ok: true, error: null}
        }
        let ok = $val.ok
        if $ok {
            return {declared: true, ok: true, error: null}
        }
        let cols = (try { $val | columns } catch { [] })
        let err = (
            if ("error" in $cols) and ((try { $val.error | describe } catch { "other" }) == "string") {
                outcome-short $val.error
            } else {
                "failed"
            }
        )
        return {declared: true, ok: false, error: $err}
    }
    if ($d | str starts-with "table") or ($d | str starts-with "list") {
        if ($val | is-empty) {
            return {declared: false, ok: true, error: null}
        }
        let rows_ok = (try { $val | all {|r| outcome-row $r } } catch { false })
        if not $rows_ok {
            return {declared: false, ok: true, error: null}
        }
        let n = ($val | length)
        let n_fail = ($val | where {|r| $r.ok == false } | length)
        if $n_fail == 0 {
            return {declared: true, ok: true, error: null}
        }
        return {declared: true, ok: false, error: $"($n_fail) of ($n) failed"}
    }
    {declared: false, ok: true, error: null}
}
