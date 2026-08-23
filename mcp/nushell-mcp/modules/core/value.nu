# value — shared value facts and NUON measurement.
# Internal source of the one `bytes` definition; agent-facing census is `shape`.
# Not re-exported by the dataspection façade.

use ./failure.nu ["failure fields"]

# Closed type name: table | list | record | string | int | … | other
export def "value kind" []: any -> string {
    let d = (try { $in | describe --no-collect } catch { "other" })
    if ($d | str starts-with "table") { "table"
    } else if ($d | str starts-with "list") { "list"
    } else if ($d | str starts-with "record") { "record"
    } else if $d in [
        "string" "int" "float" "bool" "datetime" "duration"
        "filesize" "nothing" "binary" "closure"
    ] { $d
    } else { "other" }
}

# Column names, or [] if the value has none.
export def "value columns" []: any -> list<string> {
    try { $in | columns } catch { [] }
}

# NUON serialization + UTF-8 byte length. Unserializable is data, not a throw.
export def "value nuon" []: any -> record {
    try {
        let s = ($in | to nuon --raw)
        {
            ok: true
            bytes: ($s | str length --utf-8-bytes)
            nuon: $s
        }
    } catch {|e|
        let f = (failure fields $e)
        {ok: false, bytes: null, nuon: "", error: $f.error, trace: $f.trace}
    }
}
