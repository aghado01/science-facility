# stream — terminal stream measurement (string UTF-8 bytes or binary length).
# Distinct from shape.bytes (NUON). Never reports zero by catch fallback.
# Not re-exported by the dataspection façade.

# {ok: true, bytes: int} | {ok: false, bytes: null, error: string}
export def "stream bytes" []: any -> record {
    let val = $in
    let d = (try { $val | describe } catch { "other" })
    if $d == "string" {
        let n = ($val | str length --utf-8-bytes)
        return {ok: true, bytes: $n}
    }
    if $d == "binary" {
        let n = ($val | bytes length)
        return {ok: true, bytes: $n}
    }
    {ok: false, bytes: null, error: $"unsupported stream type: ($d)"}
}
